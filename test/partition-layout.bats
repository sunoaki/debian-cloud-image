#!/usr/bin/env bats
# Unit tests for scripts/partition-layout.sh. Every function under test is pure:
# it takes text or numbers and returns text or a status, so nothing here mounts a
# device, needs root, or touches the host. The layouts encoded below come from
# real images (see the audit's partition tables) and from the two production
# incidents: a 15-slot kernel limit hiding Ubuntu's /boot, and a heuristic that
# read Debian's in-root /boot/grub as a missing partition.

setup() {
  source "$BATS_TEST_DIRNAME/../scripts/partition-layout.sh"
}

# --- candidates ------------------------------------------------------------

@test "blkid candidates keep only the target disk and real filesystems" {
  local out
  out="$(layout_candidates_from_blkid /dev/nbd0 '/dev/nbd0p1: TYPE="ext4"
/dev/nbd0p15: TYPE="vfat"
/dev/nbd0p16: TYPE="ext4"
/dev/nbd1p1: TYPE="ext4"
/dev/sda1: TYPE="xfs"')"

  [[ "$out" == *"/dev/nbd0p1"* ]]
  [[ "$out" == *"/dev/nbd0p16"* ]]
  # vfat is the EFI system partition, not something to mount as root
  [[ "$out" != *"nbd0p15"* ]]
  # a different disk must not leak in
  [[ "$out" != *"nbd1p1"* ]]
  [[ "$out" != *"sda1"* ]]
}

@test "lsblk candidates fall back to ext4 rows only" {
  local out
  out="$(layout_candidates_from_lsblk 'nbd0p1 ext4
nbd0p15 vfat
nbd0p16 ext4')"

  [ "$out" = "$(printf '/dev/nbd0p1\n/dev/nbd0p16')" ]
}

# --- classification --------------------------------------------------------

@test "a filesystem with etc is root" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/etc"
  [ "$(layout_classify_mount "$dir")" = "root" ]
}

@test "a filesystem with grub at top level is boot" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/grub"
  [ "$(layout_classify_mount "$dir")" = "boot" ]
}

@test "root wins over boot when both markers are present" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/etc" "$dir/grub"
  [ "$(layout_classify_mount "$dir")" = "root" ]
}

# This is the production bug: Debian has no separate /boot, its grub lives at
# /boot/grub inside root. Probing a Debian root must classify it as root, never
# as boot -- reading "grub/ is present" as "a partition was skipped" is what
# failed debian-12 and debian-13 in CI.
@test "a Debian-style root with boot/grub inside is root, never boot" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/etc" "$dir/boot/grub"
  [ "$(layout_classify_mount "$dir")" = "root" ]
}

@test "an empty filesystem is neither root nor boot" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir"
  [ -z "$(layout_classify_mount "$dir")" ]
}

# --- firmware --------------------------------------------------------------

@test "an EFI system partition selects efi" {
  [ "$(layout_firmware '0fc63daf-8483-4772-8e79-3d69d8477de4
c12a7328-f81f-11d2-ba4b-00a0c93ec93b
bc13c2ff-59e6-4262-a352-b275fd6f7172')" = "efi" ]
}

@test "no EFI system partition selects bios" {
  [ "$(layout_firmware '0fc63daf-8483-4772-8e79-3d69d8477de4')" = "bios" ]
}

@test "uppercase GUIDs still select efi" {
  [ "$(layout_firmware 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B')" = "efi" ]
}

@test "an unreadable GUID list selects nothing so the caller can warn" {
  [ -z "$(layout_firmware '')" ]
}

# --- slot count (the original incident) ------------------------------------

@test "a hidden partition is detected as insufficient slots" {
  # partx reports 16 partitions, the kernel exposes 15: what max_part=8 caused.
  ! layout_slots_sufficient 15 16
}

@test "matching partition counts are sufficient" {
  layout_slots_sufficient 16 16
  # more visible nodes than table entries (e.g. stale) is not a shortfall
  layout_slots_sufficient 17 16
}

# --- boot chain verdict ----------------------------------------------------

@test "boot chain is accepted when kernel count is unchanged" {
  [ -z "$(layout_boot_chain_problem 1 1 false 1 1)" ]
}

@test "boot chain is accepted when the kernel was upgraded" {
  [ -z "$(layout_boot_chain_problem 1 1 false 2 2)" ]
}

@test "a dropped kernel count is rejected" {
  [ -n "$(layout_boot_chain_problem 1 1 false 0 0)" ]
}

@test "an image with no kernel at all is rejected" {
  [ -n "$(layout_boot_chain_problem 0 0 false 0 0)" ]
}

@test "a mounted separate /boot with no kernel is rejected" {
  [ -n "$(layout_boot_chain_problem 1 1 true 0 0)" ]
}

@test "a separate /boot holding the kernel is accepted" {
  [ -z "$(layout_boot_chain_problem 1 1 true 1 1)" ]
}

@test "losing only the initrd is rejected" {
  [ -n "$(layout_boot_chain_problem 1 1 false 1 0)" ]
}

# --- RHEL-family /boot naming ----------------------------------------------

# The production bug this covers: Rocky and CentOS keep their bootloader in
# grub2/, not grub/, so the old check returned nothing for the /boot partition,
# left it unmounted, and let kernel-install write into the root filesystem while
# GRUB kept reading stale entries from the real /boot.
@test "a RHEL-style /boot with grub2 is classified as boot" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/grub2" "$dir/loader" "$dir/efi"
  [ "$(layout_classify_mount "$dir")" = "boot" ]
}

@test "a Debian-style /boot with grub is still classified as boot" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/grub"
  [ "$(layout_classify_mount "$dir")" = "boot" ]
}

# An EFI system partition holds a bootloader but is not /boot, so efi/ alone must
# not classify it as boot (the pipeline mounts the ESP nowhere and /boot is the
# separate XBOOTLDR partition on those images).
@test "an EFI system partition with only efi/ is not classified as boot" {
  local dir="$BATS_TEST_TMPDIR/mnt"
  mkdir -p "$dir/efi/EFI/rocky"
  [ -z "$(layout_classify_mount "$dir")" ]
}

# --- /boot candidates by partition type GUID --------------------------------

@test "XBOOTLDR and ESP partition types are boot candidates" {
  local types='1 21686148-6449-6e6f-744e-656564454649
2 c12a7328-f81f-11d2-ba4b-00a0c93ec93b
3 bc13c2ff-59e6-4262-a352-b275fd6f7172
4 4f68bce3-e8cd-4db1-96e7-fbcaf984b709'

  [ "$(layout_boot_candidates_from_types "$types")" = "$(printf '2\n3')" ]
}

@test "uppercase type GUIDs are matched" {
  [ "$(layout_boot_candidates_from_types '2 BC13C2FF-59E6-4262-A352-B275FD6F7172')" = "2" ]
}

# Debian and Ubuntu have no XBOOTLDR and their ESP is not /boot, so a Debian
# image yields exactly one candidate (the ESP) and the content check rejects it.
@test "a Debian layout yields only the ESP as a candidate" {
  local types='1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b
16 0fc63daf-8483-4772-8e79-3d69d8477de4'
  [ "$(layout_boot_candidates_from_types "$types")" = "1" ]
}

@test "a table with no boot or ESP type yields no candidates" {
  [ -z "$(layout_boot_candidates_from_types '1 0fc63daf-8483-4772-8e79-3d69d8477de4')" ]
}

# --- filesystem-aware growth ------------------------------------------------

@test "ext4 grows offline, before the mount" {
  [ "$(layout_grow_recipe ext4)" = "offline" ]
}

# Rocky and CentOS roots are XFS and must be grown through the mountpoint.
@test "xfs grows through the mountpoint" {
  [ "$(layout_grow_recipe xfs)" = "mounted" ]
}

@test "an unknown filesystem yields no recipe so the caller can fail loudly" {
  [ -z "$(layout_grow_recipe btrfs)" ]
}

# --- checksum parsing across formats ----------------------------------------

# The original one-liner (`awk '$2 == f'`) matched only the GNU shape, so Rocky's
# BSD-style .CHECKSUM parsed as empty and the download step exited 1.
@test "GNU-format checksums are matched" {
  local sums='a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2  debian-13.qcow2'
  [ "$(layout_checksum_for "$sums" debian-13.qcow2)" = \
    "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" ]
}

@test "GNU binary-marker checksums are matched" {
  local sums='9fc9e9ff16888bb68ac39b0392e25c9c92684d50c85f1cce6ab549363bbc4b48 *noble.img'
  [ "$(layout_checksum_for "$sums" noble.img)" = \
    "9fc9e9ff16888bb68ac39b0392e25c9c92684d50c85f1cce6ab549363bbc4b48" ]
}

# Rocky's real format, taken verbatim from the published file.
@test "BSD-format checksums are matched" {
  local sums='# Rocky-9-GenericCloud-Base.latest.x86_64.qcow2: 645988352 bytes
SHA256 (Rocky-9-GenericCloud-Base.latest.x86_64.qcow2) = 92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8'
  [ "$(layout_checksum_for "$sums" Rocky-9-GenericCloud-Base.latest.x86_64.qcow2)" = \
    "92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8" ]
}

# The comment line carries the byte size; it must not be read as the hash.
@test "a size comment line is not mistaken for the hash" {
  local sums='# Rock.qcow2: 645988352 bytes'
  [ -z "$(layout_checksum_for "$sums" Rock.qcow2)" ]
}

@test "an absent filename yields nothing so the caller can fail loudly" {
  local sums='a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2  debian-13.qcow2'
  [ -z "$(layout_checksum_for "$sums" rocky.qcow2)" ]
}

# A short hash must not be picked up: the fields in these files include sizes.
@test "a short hex field is not treated as the hash" {
  local sums='# Rock.qcow2: 645988352 bytes'
  [ -z "$(layout_checksum_for "$sums" Rock.qcow2)" ]
}
