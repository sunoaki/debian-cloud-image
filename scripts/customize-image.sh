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
if [ "$kernel_parts" -lt "$table_parts" ]; then
  echo "Only $kernel_parts of $table_parts partitions on $DISKDEV are visible to the kernel;" >&2
  echo "a partition would be skipped, so refusing to continue." >&2
  partx --show "$DISKDEV" >&2 2>/dev/null || true
  exit 1
fi

# Record the partition type GUIDs now that the disk is attached: the advisory
# boot test in the workflow needs them to choose BIOS or UEFI firmware, and a
# qcow2 cannot be probed directly (sfdisk reads the container, not the table).
# /tmp is on the same runner for the rest of the job.
lsblk -rno PARTTYPE "$DISKDEV" 2>/dev/null | grep -v '^$' > /tmp/parttypes.txt || true
if [ -s /tmp/parttypes.txt ]; then
  if grep -qi '^c12a7328-f81f-11d2-ba4b-00a0c93ec93b$' /tmp/parttypes.txt; then
    echo "efi" > /tmp/firmware.txt
  else
    echo "bios" > /tmp/firmware.txt
  fi
  echo "Firmware for boot test: $(cat /tmp/firmware.txt) (from $(wc -l < /tmp/parttypes.txt) partition type GUIDs)"
else
  rm -f /tmp/firmware.txt
  echo "WARN: could not read partition type GUIDs; boot test will fall back to BIOS" >&2
fi

# Detect the real root partition by mounting each candidate and checking for
# /etc. Layouts differ: Debian 12/13 and Ubuntu 22.04 use a single ext4 p1;
# Ubuntu >= 24.04 also uses p1 as root but puts a standalone /boot on p16 with
# EFI on p15. Root is therefore identified by content, not by partition number.
# blkid reads devices directly (no udev cache); lsblk is the fallback.
CANDIDATES=$(blkid | awk -F: -v d="$DISKDEV" 'index($1,d)==1 && $0 ~ /TYPE="(ext4|xfs|btrfs)"/ {sub(/:/,"",$1); print $1}')
if [ -z "$CANDIDATES" ]; then
  CANDIDATES=$(lsblk -rno NAME,FSTYPE "$DISKDEV" | awk '$2=="ext4" {print "/dev/"$1}')
fi
mkdir -p /tmp/probe
for dev in $CANDIDATES; do
  if mount "$dev" /tmp/probe >/dev/null 2>&1; then
    if [ -d /tmp/probe/etc ] && [ -z "$ROOTDEV" ]; then
      ROOTDEV="$dev"
      echo "Root partition: $dev"
    elif [ -d /tmp/probe/grub ] && [ -z "$BOOTDEV" ]; then
      # A standalone /boot partition has grub/ at its top level, unlike a root
      # partition where it lives under /boot/grub.
      BOOTDEV="$dev"
      echo "Boot partition: $dev"
    fi
    umount /tmp/probe
  fi
done
if [ -z "$ROOTDEV" ]; then
  echo "Could not locate the root partition on $DISKDEV" >&2
  blkid | grep "$DISKDEV" || true
  exit 1
fi

# Grow the root filesystem to fill the space added by qemu-img resize. growpart
# and e2fsck legitimately return non-zero (partition already maximal; errors
# found and fixed), so only resize2fs is allowed to fail the build: if it does
# not grow, the chroot apt run below dies with ENOSPC far from the real cause.
# The resulting free space is asserted *after* the mount below: running df on an
# unmounted device reports the host's /dev tmpfs, not the partition.
ROOTNUM=$(echo "$ROOTDEV" | grep -oE '[0-9]+$')
growpart "$DISKDEV" "$ROOTNUM" || true
e2fsck -fy "$ROOTDEV" >/dev/null 2>&1 || true
resize2fs "$ROOTDEV"

mkdir -p "$MNT"
mount "$ROOTDEV" "$MNT"
if [ -n "$BOOTDEV" ]; then
  mount "$BOOTDEV" "$MNT/boot"
fi

# Fail here rather than inside the chroot if the resize above did not take: the
# package install then dies with ENOSPC, which points nowhere near the cause.
AVAIL_KB=$(df -Pk "$MNT" | awk 'NR==2 {print $4}')
[ "$AVAIL_KB" -ge 1048576 ] || {
  echo "Only ${AVAIL_KB}KiB free on $MNT after resize2fs; the package install needs more." >&2
  exit 1
}

# Baseline for the post-chroot boot-chain assertion below (see assert_boot_chain).
BASE_KERNELS=$(compgen -G "$MNT/boot/vmlinuz-*" | wc -l || true)
BASE_INITRDS=$(compgen -G "$MNT/boot/initrd.img-*" | wc -l || true)
echo "Boot chain before customization: $BASE_KERNELS kernel(s), $BASE_INITRDS initrd(s)"

# Bind host runtime dirs so apt/dpkg/update-grub work inside the chroot.
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

# DNS inside the chroot; restore the original file afterwards.
RESOLV_BACKUP=/tmp/resolv.conf.orig
cp -a "$MNT/etc/resolv.conf" "$RESOLV_BACKUP"
rm -f "$MNT/etc/resolv.conf"
echo "nameserver 1.1.1.1" > "$MNT/etc/resolv.conf"

# Seed apt's download cache from a previous run (if any).
if [ -d "$REPO_ROOT/.apt-cache" ] && ls "$REPO_ROOT/.apt-cache"/*.deb >/dev/null 2>&1; then
  cp -n "$REPO_ROOT/.apt-cache"/*.deb "$MNT/var/cache/apt/archives/" || true
fi

# Stage the rootfs customization script, package list and sysctl template
# into the image.
install -m 0755 "$SCRIPT_DIR/customize-rootfs.sh" "$MNT/tmp/customize-rootfs.sh"
install -m 0644 "$PACKAGES_FILE" "$MNT/tmp/cloud-image-packages.txt"
install -m 0644 "$SYSCTL_FILE" "$MNT/tmp/cloud-image-sysctl.conf"

chroot "$MNT" /usr/bin/env \
  SOURCES_FILE="$SOURCES_FILE" \
  CLOUD_CFG="$CLOUD_CFG" \
  SOURCES_FORMAT="$SOURCES_FORMAT" \
  PACKAGES_FILE=/tmp/cloud-image-packages.txt \
  SYSCTL_FILE=/tmp/cloud-image-sysctl.conf \
  /bin/bash /tmp/customize-rootfs.sh

# Hard verification tier: assert the boot chain landed where the firmware will
# look. Pre-existing damage is recorded as a baseline before customization and
# only *regressions* fail, so an image that never had a standalone /boot (or
# never had a bootloader) is not held to a contract it did not have before.
# Runs after the chroot because that is when a new kernel/initrd appear.
kernel_count() {
  compgen -G "$MNT/boot/vmlinuz-*" | wc -l || true
}
initrd_count() {
  compgen -G "$MNT/boot/initrd.img-*" | wc -l || true
}
sync_boot_to_root() {
  # If the bootloader lives on a separate partition, /boot must be mounted for
  # grub-mkconfig to reach it. Otherwise the kernel apt just installed sits in
  # the root filesystem while the real /boot keeps the previous one.
  [ -d "$MNT/boot/grub" ] || return 0
  mountpoint -q "$MNT/boot" && return 0
  echo "Bootloader present at $MNT/boot/grub but /boot is not a separate partition;" >&2
  echo "the chroot wrote its kernel to the root filesystem instead." >&2
  exit 1
}
assert_boot_chain() {
  local now_k now_i
  now_k="$(kernel_count)"
  now_i="$(initrd_count)"
  echo "Boot chain: $now_k kernel(s) and $now_i initrd(s) under /boot"
  if [ "$now_k" -lt "$BASE_KERNELS" ] || [ "$now_i" -lt "$BASE_INITRDS" ]; then
    echo "Boot chain regressed: $BASE_KERNELS kernel(s) / $BASE_INITRDS initrd(s)" >&2
    echo "before customization, $now_k / $now_i after. A chroot build writes its" >&2
    echo "kernel to /boot, so this means the mount layout is wrong." >&2
    exit 1
  fi
  [ "$now_k" -ge 1 ] || {
    echo "No kernel under /boot after customization; the image could not boot." >&2
    exit 1
  }
}

# Boot-chain assertions run before the apt cache is exported and while /boot (if
# separate) is still mounted.
sync_boot_to_root
assert_boot_chain

# Export downloaded .debs for the cache, then scrub apt state from the image.
mkdir -p "$REPO_ROOT/.apt-cache"
cp -n "$MNT/var/cache/apt/archives/"*.deb "$REPO_ROOT/.apt-cache/" || true
rm -rf "$MNT/var/lib/apt/lists" "$MNT/var/cache/apt/archives" "$MNT/var/cache/apt/partial"

# Restore resolv.conf; cleanup() handles umounts + detach on exit.
cp -a "$RESOLV_BACKUP" "$MNT/etc/resolv.conf"
RESOLV_BACKUP=
echo "customize-image.sh done"
