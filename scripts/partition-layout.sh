#!/usr/bin/env bash
# partition-layout.sh
# Pure decision logic for locating the root and /boot partitions of a cloud
# image. Every function here takes text or numbers and returns text or a status;
# none of them touch a device, mount anything or need root, so all of it is
# unit-testable with bats. customize-image.sh owns the imperative part (nbd,
# mounts, chroot) and calls into these.
#
# This split exists because the layout rules are the part that has been wrong
# before: a 15-slot kernel partition limit once hid Ubuntu's standalone /boot
# and a heuristic later mis-identified Debian's /boot. Both were decisions made
# in this file's domain, and neither was covered by a test.

# Print the devices on $1 worth probing, given raw `blkid` output as $2.
# blkid reads the device directly (no udev cache), which matters for nbd.
layout_candidates_from_blkid() {
  local diskdev="$1" blkid_output="$2"
  printf '%s\n' "$blkid_output" | awk -F: -v d="$diskdev" \
    'index($1,d)==1 && $0 ~ /TYPE="(ext4|xfs|btrfs)"/ {sub(/:/,"",$1); print $1}'
}

# Fallback for when blkid reports nothing: raw `lsblk -rno NAME,FSTYPE` output.
layout_candidates_from_lsblk() {
  printf '%s\n' "$1" | awk '$2=="ext4" {print "/dev/"$1}'
}

# Classify a mounted filesystem by what sits at its top level, printing "root",
# "boot" or nothing.
#
# A root filesystem has etc/. A standalone /boot has a bootloader directory at
# its top level: Debian and Ubuntu keep it in grub/, RHEL-family images (Rocky,
# CentOS) keep it in grub2/. Either is accepted; the RHEL spelling is why this
# function used to return nothing for Rocky and left /boot unmounted.
#
# Note that a separate /boot *existing* and a /boot *being missed* are different
# things: Debian ships /boot/grub inside root and has no separate partition at
# all, so a bootloader directory alone must not be read as "a partition was
# skipped". root/ is checked first for exactly that reason.
#
# loader/ and efi/ are accepted as supporting evidence for a boot partition, but
# only when a bootloader directory is also present, so an ESP is not mistaken for
# /boot just because it contains efi/.
layout_classify_mount() {
  local dir="$1"
  if [ -d "$dir/etc" ]; then
    printf 'root\n'
  elif [ -d "$dir/grub" ] || [ -d "$dir/grub2" ]; then
    printf 'boot\n'
  fi
}

# Print the partition numbers (one per line, in table order) whose *type GUID*
# marks them as a /boot candidate.
#
# Two GUIDs count: the XBOOTLDR partition type, and the EFI System Partition
# type. XBOOTLDR is exactly what Rocky and CentOS use for their standalone
# /boot, so it identifies the partition without depending on what a distro names
# the directory inside it. Callers must still confirm by content: Debian's
# /boot is a plain directory in root and has no entry here at all, and an ESP
# holds a bootloader without being /boot.
#
# Input: raw `partx --show --noheadings -o NR,TYPE` output (number, GUID per line).
layout_boot_candidates_from_types() {
  local types="$1"
  printf '%s\n' "$types" | awk '
    tolower($2) == "bc13c2ff-59e6-4262-a352-b275fd6f7172" ||
    tolower($2) == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print $1 }'
}


# Print the firmware a boot test should use, given GPT partition type GUIDs one
# per line ($1). Prints nothing when the list is empty, so the caller can warn
# and fall back rather than silently choosing.
layout_firmware() {
  local guids="$1"
  [ -n "$guids" ] || return 0
  if printf '%s\n' "$guids" | grep -qi '^c12a7328-f81f-11d2-ba4b-00a0c93ec93b$'; then
    printf 'efi\n'
  else
    printf 'bios\n'
  fi
}

# Succeeds when the kernel exposes at least as many partitions as the on-disk
# table declares. A shortfall means a partition is invisible to us, which is how
# the standalone /boot went missing.
layout_slots_sufficient() {
  [ "$1" -ge "$2" ]
}

# Print why the boot chain is unacceptable, or nothing when it is fine.
# Arguments: baseline kernels, baseline initrds, separate /boot was found,
# current kernels, current initrds.
#
# A *regression* or an empty /boot is a failure; a pre-existing absence is not,
# so an image that never had a standalone /boot is not held to a contract it
# did not satisfy before.
layout_boot_chain_problem() {
  local base_k="$1" base_i="$2" boot_separate="$3" now_k="$4" now_i="$5"
  if [ "$boot_separate" = "true" ] && [ "$now_k" -lt 1 ]; then
    printf 'a separate /boot was found and mounted, but holds no kernel\n'
    return 0
  fi
  if [ "$now_k" -lt "$base_k" ] || [ "$now_i" -lt "$base_i" ]; then
    printf 'boot chain regressed: %s kernel(s)/%s initrd(s) before, %s/%s after\n' \
      "$base_k" "$base_i" "$now_k" "$now_i"
    return 0
  fi
  if [ "$now_k" -lt 1 ]; then
    printf 'no kernel under /boot after customization\n'
    return 0
  fi
}

# Print how the root filesystem of $1 (a filesystem type name: ext4, xfs, ...)
# must be grown, or nothing when this module has no recipe for it.
#
# The two recipes differ in *when* they run, not just which tool they call:
#   ext4 - resize2fs works on the block device and must run while it is NOT
#          mounted (the current pipeline order: grow, then mount).
#   xfs  - xfs_growfs works through the mountpoint and the filesystem must BE
#          mounted: "The filesystem must be mounted to be grown." (man 8
#          xfs_growfs). Rocky and CentOS roots are XFS, so the pipeline's
#          existing order cannot work for them.
layout_grow_recipe() {
  case "$1" in
  ext4) printf 'offline\n' ;;
  xfs) printf 'mounted\n' ;;
  *) return 0 ;;
  esac
}


# Print the expected hash for $2 from a checksum file's contents ($1), or nothing
# when the file does not mention it.
#
# Three shapes are in play across the distros, and the original one-liner
# (`awk '$2 == f'`) silently matched only the first:
#   GNU coreutils   a1b2c3d4  name.qcow2        Debian SHA512SUMS, Ubuntu SHA256SUMS
#   GNU binary mark a1b2c3d4 *name.qcow2        Ubuntu sums files use '*'
#   BSD             SHA256 (name.qcow2) = a1b2c3d4   Rocky's .CHECKSUM
# Matching on the filename *anywhere* in the line, then taking the first
# hex-looking field, covers all three without a per-format branch. Comment lines
# (leading '#'; Rocky's per-file CHECKSUM begins with one) are ignored so a size
# annotation cannot be mistaken for a hash.
layout_checksum_for() {
  local sums="$1" want="$2"
  printf '%s\n' "$sums" | awk -v f="$want" '
    /^[[:space:]]*#/ { next }
    index($0, f) == 0 { next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9a-fA-F]{32,}$/) { print $i; exit }
      }
    }'
}
