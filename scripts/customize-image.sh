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
# efi_esp comes from config/images.yaml; only entries that ask for an EFI system
# partition set it to true. Left unset it means "do not create one".
: "${EFI_ESP:-}"
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
ESPDEV=
ESP_SIZE_SECTORS=

cleanup() {
  set +e
  if [ -n "$RESOLV_BACKUP" ] && [ -f "$RESOLV_BACKUP" ]; then
    cp -a "$RESOLV_BACKUP" "$MNT/etc/resolv.conf" 2>/dev/null
  fi
  mountpoint -q "$MNT/sys" && umount "$MNT/sys"
  mountpoint -q "$MNT/proc" && umount "$MNT/proc"
  mountpoint -q "$MNT/dev/pts" && umount "$MNT/dev/pts"
  mountpoint -q "$MNT/dev" && umount "$MNT/dev"
  mountpoint -q "$MNT/boot/efi" && umount "$MNT/boot/efi"
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

# Grow the virtual disk: stock cloud images ship tiny (2-3G) roots and package
# installs for our list run out of space (Ubuntu 22.04). The root partition ends
# after every other partition on the disk (Ubuntu >= 24.04 puts EFI and /boot
# *before* it), so the appended space sits directly after root and growpart plus
# the filesystem grow can extend it.
qemu-img resize "$SRC_IMAGE" +4G

# An entry that asks for an EFI system partition (config/images.yaml efi_esp)
# gets one appended at the end of the disk. Ask for 101MiB to get a 100MiB
# partition: the ESP is aligned down to a 1MiB boundary, which pushes its start
# above where it would otherwise be and would leave the partition short of 100MiB.
# layout_esp_geometry turns the resulting sector count into the exact start and
# end. An empty type list is the right input here: this runs before the disk is
# attached, and the point is only to reserve room when some entry asked for one.
if [ -n "$(layout_esp_plan "${EFI_ESP:-}" "")" ]; then
  qemu-img resize "$SRC_IMAGE" +101M
fi

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

# Record the partition *types* now that the disk is attached: the advisory boot
# test in the workflow needs them to choose BIOS or UEFI firmware, and a qcow2
# cannot be probed directly (sfdisk reads the container, not the table). partx
# reads the on-disk table itself; lsblk PARTTYPE depends on udev data that is not
# reliably populated for nbd devices and returned nothing on a CI run.
#
# These values double as the input to the ESP decision below: the same read tells
# us both whether an ESP is already there and what size to create when it is not.
PARTTYPES=$(partx --show --noheadings -o NR,TYPE "$DISKDEV" 2>/dev/null | awk '{print $2}' | grep -v '^$' || true)
ESP_SIZE_SECTORS=$(layout_esp_plan "${EFI_ESP:-}" "$PARTTYPES")

# Record the firmware for the boot test in the workflow, folding in the ESP this
# run is about to create rather than only the one the image arrived with:
#
#   * The types read above describe the image as it shipped, and a CentOS 7 image
#     has no ESP yet. Reporting that initial state would boot-test a
#     two-firmware image on BIOS alone, which is the path that already worked.
#   * An ESP being created means the image will boot UEFI, so efi is the right
#     value to test.
#
# The chroot is a separate question and no longer reads this value: rhel.sh pins
# each generated config to the firmware that reads it (see grub2_mkconfig_bios and
# grub2_mkconfig_efi), because on a dual-firmware image one value cannot describe
# both files. Passing FIRMWARE in would only let the *runner's* platform leak back
# in, which is what produced `linuxefi` in a BIOS-only image's config.
if [ -n "$ESP_SIZE_SECTORS" ]; then
  FIRMWARE=efi
else
  FIRMWARE=$(layout_firmware "$PARTTYPES")
fi
if [ -n "$FIRMWARE" ]; then
  echo "Firmware for boot test: $FIRMWARE (from $(printf '%s\n' "$PARTTYPES" | wc -l) partition type value(s))"
else
  echo "WARN: could not read partition types; boot test will fall back to BIOS" >&2
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

# Create the EFI system partition here, at the *end* of the disk and *before*
# root is grown. Neither choice is free, and both were measured on the lab image
# (total 33761280 sectors, ESP 204800 sectors):
#
#   * End of the disk, not directly behind root. growpart only ever extends a
#     partition as far as the next one's start, so an ESP placed immediately after
#     root caps root at its stock size and the package install then fails with
#     ENOSPC - a symptom that names nothing about its cause.
#   * Before growpart, not after. growpart rounds its result down to a whole
#     number of 1MiB units, so on this disk it put root's end at 33759231 - past
#     the 33556480 the ESP has to start at. `sfdisk --append` then failed with "no
#     free sectors available" and the image kept its single stock partition, with
#     no ESP at all. Creating the ESP first makes growpart stop exactly at its
#     start instead (root ends at 33556479, flush against the ESP), so the whole
#     gap still goes to root.
if [ -n "$ESP_SIZE_SECTORS" ]; then
  TOTAL_SECTORS=$(blockdev --getsz "$DISKDEV")
  read -r ESP_START ESP_END < <(layout_esp_geometry "$TOTAL_SECTORS" "$ESP_SIZE_SECTORS")
  ESP_PARTNUM=$((table_parts + 1))
  echo "Creating a $((ESP_SIZE_SECTORS / 2048))MiB ESP as partition $ESP_PARTNUM (sectors $ESP_START-$ESP_END)"
  # --append adds a single partition to the existing table without rewriting the
  # rest of it, which is what we want: the entries already there are left exactly
  # as the image shipped them. `type=ef` is the MBR EFI System type byte; an MBR
  # table has nowhere to store a GUID, and on MBR this byte is the only thing that
  # marks a partition as an ESP. (A GPT image would need its GUID instead; no
  # entry in the matrix does, and layout_esp_plan skips images that already have
  # an ESP, so this is MBR-only by construction.)
  printf 'start=%s, size=%s, type=ef\n' "$ESP_START" "$ESP_SIZE_SECTORS" |
    sfdisk --no-reread --append "$DISKDEV"
  partprobe "$DISKDEV" || true
  ESPDEV=$(layout_partition_dev "$DISKDEV" "$ESP_PARTNUM")
  wait_for_partitions "$((table_parts + 1))" || {
    echo "Timed out waiting for the new ESP node $ESPDEV to appear" >&2
    exit 1
  }
  # mkfs.vfat is on the runner, not in the image: the stock CentOS 7 image has no
  # dosfstools, and the chroot cannot format the ESP for that reason. Formatting
  # from the host also avoids mounting the image's own /boot/efi before its
  # bootloader has been installed. The workflow installs dosfstools explicitly
  # rather than relying on the runner image happening to carry it.
  mkfs.vfat -F 32 -n EFI "$ESPDEV" >/dev/null
  # Record how to reach it on the finished system: the ESP has no directory in
  # the image yet, and the chroot hook appends this line to /etc/fstab so the
  # kernel updates of a running VM refresh /boot/efi too.
  ESP_UUID=$(blkid -o value -s UUID "$ESPDEV")
  [ -n "$ESP_UUID" ] || {
    echo "Could not read a filesystem UUID from the new ESP $ESPDEV" >&2
    exit 1
  }
  echo "ESP ready: $ESPDEV UUID=$ESP_UUID"
fi

# Grow the root filesystem to fill the space added by qemu-img resize. The
# recipe depends on the filesystem, and so does *when* it runs:
#   ext4 (Debian/Ubuntu) - resize2fs acts on the device and must run unmounted.
#   xfs  (Rocky/CentOS)  - xfs_growfs acts through the mountpoint and the
#                          filesystem must be mounted (man 8 xfs_growfs).
# growpart legitimately returns non-zero when the partition is already maximal.
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
# Mount the new ESP so the chroot can install the EFI bootloader onto it. This is
# a real mount of the image's own filesystem, so the files the chroot writes are
# the ones the firmware will read; the payloads are copied from the image's own
# RPMs rather than only from this runner.
if [ -n "$ESPDEV" ]; then
  mkdir -p "$MNT/boot/efi"
  mount "$ESPDEV" "$MNT/boot/efi"
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
#
# FIRMWARE is deliberately *not* passed into the chroot. It used to be, back when
# one value described the whole image; with an ESP and an MBR path in the same
# image it cannot, and the family hooks pin each config file to the firmware that
# reads it instead (see grub2_mkconfig_bios / grub2_mkconfig_efi in rhel.sh). What
# is left of it is a boot-test value for the workflow, handed over through
# $GITHUB_ENV above.
export SOURCES_FILE CLOUD_CFG SOURCES_FORMAT FAMILY
# ESP_UUID travels in as the value to write into /etc/fstab: inside the chroot the
# ESP's device node is the runner's (/dev/nbd0p2), which is not the name the image
# will use, and fstab must name a stable filesystem UUID anyway. The image's own
# /etc/fstab has no ESP entry at all, so without this a kernel update on a running
# VM would rewrite /boot/efi nowhere and the firmware would keep reading the old
# payload.
export ESP_UUID="${ESP_UUID:-}"
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
