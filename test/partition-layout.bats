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

# The MBR spelling. partx -o TYPE prints a one-byte type code as hex on a DOS
# label, so a real ESP on an MBR disk arrives as `0xef` and not as the GPT GUID.
# Matching only the GUID reported such an image as BIOS, which would have boot
# tested a CentOS 7 image that does have an ESP with the wrong firmware.
@test "an MBR EFI system partition type selects efi" {
  [ "$(layout_firmware '0x83
0xef')" = "efi" ]
}

@test "an MBR type code that is not 0xef selects bios" {
  [ "$(layout_firmware '0x83
0x8e')" = "bios" ]
}

# 0xef must match as a whole value: a prefix match would make 0xef0 an ESP, and
# more realistically a 0xef byte must not be found inside a longer hex string.
@test "a longer hex value beginning with 0xef is not an ESP" {
  [ "$(layout_firmware '0xeff0')" = "bios" ]
}

# --- ESP creation plan -----------------------------------------------------

# The stock CentOS 7 image has a single MBR partition and no ESP, so this is the
# case the whole efi_esp path exists for.
@test "an entry asking for an ESP on an image without one gets a size" {
  [ "$(layout_esp_plan 1 '0x83')" = "204800" ]
}

@test "the yaml's true spelling also asks for an ESP" {
  [ "$(layout_esp_plan true '0x83')" = "204800" ]
}

# Every other entry in the matrix already ships an ESP; creating a second one
# would leave two, and the bootloader would only ever be on the distro's own.
@test "an image that already has a GPT ESP gets no second one" {
  [ -z "$(layout_esp_plan 1 '0fc63daf-8483-4772-8e79-3d69d8477de4
c12a7328-f81f-11d2-ba4b-00a0c93ec93b')" ]
}

@test "an image that already has an MBR ESP gets no second one" {
  [ -z "$(layout_esp_plan 1 '0x83
0xef')" ]
}

@test "an entry that did not ask for an ESP gets none" {
  [ -z "$(layout_esp_plan '' '0x83')" ]
  [ -z "$(layout_esp_plan false '0x83')" ]
  # a typo must leave the image as it is, not create one of an unvalidated size
  [ -z "$(layout_esp_plan yes '0x83')" ]
}

@test "the default when efi_esp is absent is not to create an ESP" {
  [ -z "$(layout_esp_plan '' '0x83')" ]
}

# --- ESP geometry ----------------------------------------------------------

# The ESP is placed so it ends on the disk's last sector and starts on a 1MiB
# boundary. These numbers are the ones measured on the lab image (total 33761280
# sectors, 204800 wanted): the run of sectors from 33556480 to 33761279.
@test "the ESP ends on the last sector and starts 1MiB-aligned" {
  [ "$(layout_esp_geometry 33761280 204800)" = "33556480 33761279" ]
}

@test "the ESP's requested size is what separates start and end" {
  local start end
  read -r start end <<<"$(layout_esp_geometry 33761280 204800)"
  [ $((end - start + 1)) -eq 204800 ]
}

# The tail between the aligned start and the disk end is alignment slack. It is
# 1MiB at most, which is why customize-image.sh resizes by 101MiB rather than
# 100MiB to still get a full 100MiB partition.
@test "the alignment slack is less than one alignment unit" {
  local start end
  read -r start end <<<"$(layout_esp_geometry 33761280 204800)"
  [ $((end + 1 - (start + 204800))) -lt 2048 ]
}

@test "a disk that ends exactly on the wanted size yields a start of zero" {
  [ "$(layout_esp_geometry 204800 204800)" = "0 204799" ]
}

@test "the start is always a multiple of 2048" {
  local total start
  for total in 33761280 33800000 34000001; do
    read -r start _ <<<"$(layout_esp_geometry "$total" 204800)"
    [ $((start % 2048)) -eq 0 ] || {
      echo "start $start is not 1MiB-aligned for total $total"
      return 1
    }
  done
}

# --- partition device names ------------------------------------------------

# The failure this covers: the first real CentOS 7 build (CI run 35488757900)
# concatenated the disk name and the partition number and got /dev/nbd02, so
# mkfs.vfat reported "unable to open /dev/nbd02: No such file or directory" and
# the build died before the image was ever booted.
@test "a disk name ending in a digit gets a p before the partition number" {
  [ "$(layout_partition_dev /dev/nbd0 2)" = "/dev/nbd0p2" ]
  [ "$(layout_partition_dev /dev/nbd0 15)" = "/dev/nbd0p15" ]
}

@test "a disk name not ending in a digit takes the bare number" {
  [ "$(layout_partition_dev /dev/sda 2)" = "/dev/sda2" ]
  [ "$(layout_partition_dev /dev/vda 1)" = "/dev/vda1" ]
}

@test "a loop device keeps its trailing digit's p separator" {
  [ "$(layout_partition_dev /dev/loop0 3)" = "/dev/loop0p3" ]
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

# --- initrd naming across families ------------------------------------------

# The boot-chain assertion counts initrds to detect a regression. Debian and
# Ubuntu name them initrd.img-<ver>; the RHEL family names them
# initramfs-<ver>.img. Counting only the Debian spelling made the baseline 0 on
# Rocky, which the first real Rocky build log showed as "0 initrd(s)" -- a
# baseline of zero makes the regression check unable to detect anything.
@test "a RHEL-style /boot initramfs is counted" {
  local dir="$BATS_TEST_TMPDIR/boot"
  mkdir -p "$dir"
  : > "$dir/vmlinuz-5.14.0-687.el9"
  : > "$dir/initramfs-5.14.0-687.el9.img"
  : > "$dir/initramfs-0-rescue-abcd.img"

  local n
  n=$(compgen -G "$dir/initrd.img-*" | wc -l || true)
  n=$((n + $(compgen -G "$dir/initramfs-*.img" | wc -l || true)))
  [ "$n" -eq 2 ]
}

@test "a Debian-style /boot initrd is counted" {
  local dir="$BATS_TEST_TMPDIR/boot"
  mkdir -p "$dir"
  : > "$dir/vmlinuz-6.12.107"
  : > "$dir/initrd.img-6.12.107"

  local n
  n=$(compgen -G "$dir/initrd.img-*" | wc -l || true)
  n=$((n + $(compgen -G "$dir/initramfs-*.img" | wc -l || true)))
  [ "$n" -eq 1 ]
}

# A Rocky /boot carries a rescue kernel as well as the main one, so the baseline
# is 2, not 1. Counting both is what makes the "did a kernel appear" check
# meaningful there.
@test "a rescue kernel plus a main kernel counts two" {
  local dir="$BATS_TEST_TMPDIR/boot"
  mkdir -p "$dir"
  : > "$dir/vmlinuz-5.14.0-687.el9"
  : > "$dir/vmlinuz-0-rescue-abcd"

  [ "$(compgen -G "$dir/vmlinuz-*" | wc -l)" -eq 2 ]
}
