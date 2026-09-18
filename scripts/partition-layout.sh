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
# A root filesystem has etc/. A standalone /boot has grub/ at its top level,
# whereas on a root filesystem grub lives under boot/grub and is therefore not
# visible here. Note that a separate /boot *existing* and a /boot *being missed*
# are different things: Debian ships /boot/grub inside root and has no separate
# partition at all, so "grub/ is present" alone must not be read as "a partition
# was skipped".
layout_classify_mount() {
  local dir="$1"
  if [ -d "$dir/etc" ]; then
    printf 'root\n'
  elif [ -d "$dir/grub" ]; then
    printf 'boot\n'
  fi
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
