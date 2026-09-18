#!/usr/bin/env bash
# customize-image.sh
# Runs on the GitHub runner (as root, see workflow `sudo -E bash`). Handles the
# qcow2 host-side plumbing: resize, NBD/loop attach, root/boot partition
# detection, growpart, bind mounts, chroot into the image, then clean teardown.
# All failure paths unwind through a trap so no NBD/loop/mount is left behind.
#
# The image is customized in place under $SRC_IMAGE and never renamed here; the
# workflow compresses it into its published RELEASE_NAME afterwards. Callers
# that still pass IMAGE_NAME keep working.
set -Eeuo pipefail

SRC_IMAGE="${SRC_IMAGE:-${IMAGE_NAME:-}}"
: "${SRC_IMAGE:?SRC_IMAGE (or IMAGE_NAME) is required}"
: "${SOURCES_FILE:?SOURCES_FILE is required}"
: "${CLOUD_CFG:?CLOUD_CFG is required}"
: "${SOURCES_FORMAT:?SOURCES_FORMAT is required}"
: "${PACKAGES_FILE:-}" # defaults to config/cloud-image-packages.txt in repo root
: "${SYSCTL_FILE:-}"   # defaults to config/cloud-image-sysctl.conf in repo root
[ -f "$SRC_IMAGE" ] || { echo "image not found: $SRC_IMAGE" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root (workflow: sudo -E bash scripts/customize-image.sh)" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_FILE="${PACKAGES_FILE:-$REPO_ROOT/config/cloud-image-packages.txt}"
SYSCTL_FILE="${SYSCTL_FILE:-$REPO_ROOT/config/cloud-image-sysctl.conf}"
[ -f "$PACKAGES_FILE" ] || { echo "packages file not found: $PACKAGES_FILE" >&2; exit 1; }
[ -f "$SYSCTL_FILE" ] || { echo "sysctl file not found: $SYSCTL_FILE" >&2; exit 1; }

# Layout decisions live in a separate sourced file so they are unit-testable;
# see test/partition-layout.bats. Those rules have been wrong before.
# shellcheck source=scripts/partition-layout.sh
. "$SCRIPT_DIR/partition-layout.sh"

MNT=/mnt/img
DISKDEV=
BOOTDEV=
ROOTDEV=
ATTACHED_NBD=false
RESOLV_BACKUP=

cleanup() {
  set +e
  if [ -n "$RESOLV_BACKUP" ] && [ -f "$RESOLV_BACKUP" ]; then
    cp -a "$RESOLV_BACKUP" "$MNT/etc/resolv.conf" 2>/dev/null
  fi
  mountpoint -q "$MNT/sys" && umount "$MNT/sys"
  mountpoint -q "$MNT/proc" && umount "$MNT/proc"
  mountpoint -q "$MNT/dev/pts" && umount "$MNT/dev/pts"
  mountpoint -q "$MNT/dev" && umount "$MNT/dev"
  mountpoint -q "$MNT/boot" && umount "$MNT/boot"
  mountpoint -q "$MNT" && umount "$MNT"
  if [ "$ATTACHED_NBD" = "true" ]; then
    qemu-nbd -d /dev/nbd0 2>/dev/null
  elif [ -n "$DISKDEV" ]; then
    losetup -d "$DISKDEV" 2>/dev/null
  fi
  rm -f /tmp/disk.raw /tmp/resolv.conf.orig
  set -e
}
trap cleanup EXIT

# Grow the virtual disk: stock cloud images ship tiny (2-3G) roots and apt
# installs for our package list run out of space (Ubuntu 22.04). The root
# partition ends after every other partition on the disk (Ubuntu >= 24.04 puts
# EFI and /boot *before* it), so the appended space sits directly after root and
# growpart + resize2fs can extend it.
qemu-img resize "$SRC_IMAGE" +4G

# Attach the image as a block device. qemu-nbd reads qcow2 directly; fall back
# to losetup + raw conversion if the nbd module is missing.
#
# Do not pass max_part: it *reduces* the slots per device rather than raising
# them. The kernel derives slots as (1 << fls(max_part)) - 1, so max_part=8
# exposes only 15 partitions, while the module default of 16 exposes 31. The
# Ubuntu >= 24.04 images carry 16 partitions and the last one is the standalone
# /boot, so a 15-slot limit hides it from blkid entirely and /boot never gets
# mounted. The slot count is asserted below before anything is trusted.
modprobe nbd 2>/dev/null || true
# A previous interrupted run can leave /dev/nbd0 attached; clear it so the
# fallback path below is only taken when qemu-nbd is genuinely unusable.
qemu-nbd -d /dev/nbd0 >/dev/null 2>&1 || true
if qemu-nbd -c /dev/nbd0 "$SRC_IMAGE"; then
  ATTACHED_NBD=true
  DISKDEV=/dev/nbd0
else
  echo "qemu-nbd unavailable, falling back to losetup..."
  qemu-img convert -O raw "$SRC_IMAGE" /tmp/disk.raw
  DISKDEV=$(losetup --find --show --partscan /tmp/disk.raw)
fi
partprobe "$DISKDEV" || true

# Wait for the kernel partition nodes instead of sleeping a fixed 2s: a slow
# runner may not be ready in time, and a fast one wastes the wait. Poll until
# the count reported by partx is reached. Reading the table itself can fail
# (unreadable device, no block layer), so that is a separate hard failure --
# treating it as "0 partitions expected" would make the poll a no-op.
table_parts=$(partx --show --noheadings "$DISKDEV" 2>/dev/null | wc -l || true)
[ "$table_parts" -gt 0 ] || {
  echo "Could not read a partition table from $DISKDEV" >&2
  exit 1
}
wait_for_partitions() {
  local want="$1" deadline=$((SECONDS + 30)) got
  while :; do
    got=$(compgen -G "${DISKDEV}p*" | wc -l || true)
    [ "$got" -ge "$want" ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}
wait_for_partitions "$table_parts" || {
  echo "Timed out waiting for the $table_parts partition node(s) of $DISKDEV to appear" >&2
  exit 1
}

# Guard against a kernel/partition-table slot mismatch. partx reads the table
# on the device itself, compgen counts the partition nodes the kernel actually
# created; if max_part were ever set below the real partition count, the
# missing nodes would silently drop the /boot partition and the only symptom
# would be a bootloader written to the wrong filesystem. Fail loudly instead.
# compgen -G leaves its non-zero status for a no-match, hence the `|| true`.
kernel_parts=$(compgen -G "${DISKDEV}p*" | wc -l || true)
if ! layout_slots_sufficient "$kernel_parts" "$table_parts"; then
  echo "Only $kernel_parts of $table_parts partitions on $DISKDEV are visible to the kernel;" >&2
  echo "a partition would be skipped, so refusing to continue." >&2
  partx --show "$DISKDEV" >&2 2>/dev/null || true
  exit 1
fi

# Record the partition type GUIDs now that the disk is attached: the advisory
# boot test in the workflow needs them to choose BIOS or UEFI firmware, and a
# qcow2 cannot be probed directly (sfdisk reads the container, not the table).
# partx reads the on-disk table itself; lsblk PARTTYPE depends on udev data that
# is not reliably populated for nbd devices and returned nothing on a CI run.
PARTTYPES=$(partx --show --noheadings -o NR,TYPE "$DISKDEV" 2>/dev/null | awk '{print $2}' | grep -v '^$' || true)
FIRMWARE=$(layout_firmware "$PARTTYPES")
if [ -n "$FIRMWARE" ]; then
  echo "Firmware for boot test: $FIRMWARE (from $(printf '%s\n' "$PARTTYPES" | wc -l) partition type GUIDs)"
else
  echo "WARN: could not read partition type GUIDs; boot test will fall back to BIOS" >&2
fi
# Hand the value to later workflow steps through $GITHUB_ENV (the file only
# exists under GitHub Actions; a local run simply skips this).
if [ -n "$FIRMWARE" ] && [ -n "${GITHUB_ENV:-}" ]; then
  echo "FIRMWARE=$FIRMWARE" >> "$GITHUB_ENV"
fi

# Detect the real root partition by mounting each candidate and checking for
# /etc. Layouts differ: Debian 12/13 and Ubuntu 22.04 use a single ext4 p1;
# Ubuntu 24.04 also uses p1 as root but puts a standalone /boot on p16 (26.04
# uses p13). Root is therefore identified by content, not by partition number.
# blkid reads devices directly (no udev cache); lsblk is the fallback.
CANDIDATES=$(layout_candidates_from_blkid "$DISKDEV" "$(blkid)")
if [ -z "$CANDIDATES" ]; then
  CANDIDATES=$(layout_candidates_from_lsblk "$(lsblk -rno NAME,FSTYPE "$DISKDEV")")
fi
mkdir -p /tmp/probe
for dev in $CANDIDATES; do
  if mount "$dev" /tmp/probe >/dev/null 2>&1; then
    case "$(layout_classify_mount /tmp/probe)" in
      root) [ -z "$ROOTDEV" ] && { ROOTDEV="$dev"; echo "Root partition: $dev"; } ;;
      boot) [ -z "$BOOTDEV" ] && { BOOTDEV="$dev"; echo "Boot partition: $dev"; } ;;
    esac
    umount /tmp/probe
  fi
done
if [ -z "$ROOTDEV" ]; then
  echo "Could not locate the root partition on $DISKDEV" >&2
  blkid | grep "$DISKDEV" || true
  exit 1
fi

# Grow the root filesystem to fill the space added by qemu-img resize. The
# recipe depends on the filesystem, and so does *when* it runs:
#   ext4 (Debian/Ubuntu) - resize2fs acts on the device and must run unmounted.
#   xfs  (Rocky/CentOS)  - xfs_growfs acts through the mountpoint and the
#                          filesystem must be mounted (man 8 xfs_growfs).
# growpart always runs first because it edits the partition table either way, and
# it legitimately returns non-zero when the partition is already maximal.
ROOTNUM=$(echo "$ROOTDEV" | grep -oE '[0-9]+$')
growpart "$DISKDEV" "$ROOTNUM" || true

ROOT_FS=$(blkid -o value -s TYPE "$ROOTDEV" 2>/dev/null || true)
GROW_RECIPE=$(layout_grow_recipe "$ROOT_FS")
[ -n "$GROW_RECIPE" ] || {
  echo "No growth recipe for root filesystem '${ROOT_FS:-unknown}' on $ROOTDEV;" >&2
  echo "the package install would run out of space." >&2
  exit 1
}
echo "Root filesystem: ${ROOT_FS} (grows ${GROW_RECIPE})"

if [ "$GROW_RECIPE" = "offline" ]; then
  # e2fsck returns non-zero for "errors found and fixed", so only resize2fs is
  # allowed to fail the build here.
  e2fsck -fy "$ROOTDEV" >/dev/null 2>&1 || true
  resize2fs "$ROOTDEV"
fi

mkdir -p "$MNT"
mount "$ROOTDEV" "$MNT"
if [ -n "$BOOTDEV" ]; then
  mount "$BOOTDEV" "$MNT/boot"
fi

if [ "$GROW_RECIPE" = "mounted" ]; then
  command -v xfs_growfs >/dev/null 2>&1 || {
    echo "Root is ${ROOT_FS} but xfs_growfs is not installed on this runner;" >&2
    echo "install xfsprogs, or the resize silently does nothing and the chroot" >&2
    echo "install later fails with ENOSPC." >&2
    exit 1
  }
  case "$ROOT_FS" in
  xfs) xfs_growfs "$MNT" >/dev/null ;;
  esac
fi

# Fail here rather than inside the chroot if the resize above did not take: the
# package install then dies with ENOSPC, which points nowhere near the cause.
AVAIL_KB=$(df -Pk "$MNT" | awk 'NR==2 {print $4}')
[ "$AVAIL_KB" -ge 1048576 ] || {
  echo "Only ${AVAIL_KB}KiB free on $MNT after growing ${ROOT_FS}; the package install needs more." >&2
  exit 1
}

# Baseline for the post-chroot boot-chain assertion below (see assert_boot_chain).
BASE_KERNELS=$(compgen -G "$MNT/boot/vmlinuz-*" | wc -l || true)
# initrd naming differs by family: Debian/Ubuntu use initrd.img-<ver>, the RHEL
# family uses initramfs-<ver>.img. Counting only the Debian spelling made the
# baseline 0 on Rocky, which would have made the regression check meaningless.
BASE_INITRDS=$(compgen -G "$MNT/boot/initrd.img-*" | wc -l || true)
BASE_INITRDS=$((BASE_INITRDS + $(compgen -G "$MNT/boot/initramfs-*.img" | wc -l || true)))
BASE_BOOT_SEPARATE=false
[ -n "$BOOTDEV" ] && BASE_BOOT_SEPARATE=true
echo "Boot chain before customization: $BASE_KERNELS kernel(s), $BASE_INITRDS initrd(s), separate /boot: $BASE_BOOT_SEPARATE"

# Bind host runtime dirs so apt/dpkg/update-grub work inside the chroot.
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

# DNS inside the chroot; restore the original file afterwards.
#
# Rocky ships /etc/resolv.conf as a symlink into a path that only exists once
# NetworkManager or systemd-resolved has run, so the target is usually absent.
# `cp -a` on such a link aborts the build ("cannot stat"), so only back up a real
# regular file and otherwise just replace the link. cleanup() restores the backup
# only when it exists, and re-creating a symlink is not worth the complexity: the
# image's own cloud-init/NetworkManager rewrites this file on first boot anyway.
RESOLV_BACKUP=
if [ -f "$MNT/etc/resolv.conf" ] && [ ! -L "$MNT/etc/resolv.conf" ]; then
  RESOLV_BACKUP=/tmp/resolv.conf.orig
  cp -a "$MNT/etc/resolv.conf" "$RESOLV_BACKUP"
fi
rm -f "$MNT/etc/resolv.conf"
echo "nameserver 1.1.1.1" > "$MNT/etc/resolv.conf"

# Seed apt's download cache from a previous run (if any). Debian family only:
# the RHEL family has no apt archives directory to seed.
if [ "${FAMILY:-debian}" = "debian" ] &&
  compgen -G "$REPO_ROOT/.apt-cache/*.deb" >/dev/null; then
  mkdir -p "$MNT/var/cache/apt/archives"
  cp -n "$REPO_ROOT/.apt-cache/"*.deb "$MNT/var/cache/apt/archives/" || true
fi

# Stage the rootfs customization script, package list and sysctl template
# into the image.
install -m 0755 "$SCRIPT_DIR/customize-rootfs.sh" "$MNT/tmp/customize-rootfs.sh"
install -m 0644 "$PACKAGES_FILE" "$MNT/tmp/cloud-image-packages.txt"
install -m 0644 "$SYSCTL_FILE" "$MNT/tmp/cloud-image-sysctl.conf"
# The family hooks are sourced inside the chroot, so they travel with the script.
install -d "$MNT/tmp/family"
install -m 0644 "$SCRIPT_DIR/family/"*.sh "$MNT/tmp/family/"

# FAMILY and FAMILY_DIR are exported as plain env vars rather than passed through
# `env VAR=...`: CentOS 7 ships coreutils 8.22, and while its `env` handles the
# plain form fine, exporting keeps the construct readable and side-steps the
# question entirely.
export SOURCES_FILE CLOUD_CFG SOURCES_FORMAT FAMILY
export PACKAGES_FILE=/tmp/cloud-image-packages.txt
export SYSCTL_FILE=/tmp/cloud-image-sysctl.conf
export FAMILY_DIR=/tmp/family
chroot "$MNT" /bin/bash /tmp/customize-rootfs.sh

# Hard verification tier: confirm the boot chain is where the firmware will look.
# The failure this guards against is the one observed in production: a partition
# limit hid the standalone /boot, yet root still mounted, apt still installed a
# kernel, grub-mkconfig still succeeded (it read the root filesystem's /boot),
# and the image shipped with a stale bootloader payload. The slot guard above is
# the primary detector for that; these checks confirm the result.
kernel_count() {
  compgen -G "$MNT/boot/vmlinuz-*" | wc -l || true
}
initrd_count() {
  # Both spellings: Debian/Ubuntu initrd.img-<ver>, RHEL initramfs-<ver>.img.
  local n
  n=$(compgen -G "$MNT/boot/initrd.img-*" | wc -l || true)
  n=$((n + $(compgen -G "$MNT/boot/initramfs-*.img" | wc -l || true)))
  printf '%s\n' "$n"
}
assert_boot_chain() {
  local now_k now_i problem
  now_k="$(kernel_count)"
  now_i="$(initrd_count)"
  echo "Boot chain: $now_k kernel(s) and $now_i initrd(s) under /boot"
  problem="$(layout_boot_chain_problem "$BASE_KERNELS" "$BASE_INITRDS" \
    "$BASE_BOOT_SEPARATE" "$now_k" "$now_i")"
  if [ -n "$problem" ]; then
    echo "Boot chain check failed: $problem" >&2
    echo "The chroot writes its kernel into /boot, so this means the mount layout" >&2
    echo "is wrong; see test/partition-layout.bats for the cases this covers." >&2
    exit 1
  fi
}

# Boot-chain checks run before the apt cache is exported and while root and any
# separate /boot are still mounted.
assert_boot_chain

# Export downloaded .debs for the cache, then scrub apt state from the image.
# apt-specific, so only for the debian family: an unmatched *.deb glob aborts
# under `set -e` even with `|| true`, which is how a Rocky build died here after
# its whole chroot stage had already succeeded.
if [ "${FAMILY:-debian}" = "debian" ]; then
  mkdir -p "$REPO_ROOT/.apt-cache"
  if compgen -G "$MNT/var/cache/apt/archives/*.deb" >/dev/null; then
    cp -n "$MNT/var/cache/apt/archives/"*.deb "$REPO_ROOT/.apt-cache/" || true
  fi
  rm -rf "$MNT/var/lib/apt/lists" "$MNT/var/cache/apt/archives" "$MNT/var/cache/apt/partial"
fi

# Restore resolv.conf when there was a real file to preserve; cleanup() handles
# umounts + detach on exit. A symlink original leaves RESOLV_BACKUP empty, so
# guard the same way cleanup() does: `cp -a ""` would abort the build at the very
# last step, after the chroot work had already succeeded.
if [ -n "$RESOLV_BACKUP" ] && [ -f "$RESOLV_BACKUP" ]; then
  cp -a "$RESOLV_BACKUP" "$MNT/etc/resolv.conf"
fi
RESOLV_BACKUP=
echo "customize-image.sh done"
