#!/usr/bin/env bats
# Unit tests for scripts/customize-rootfs.sh. Runs against a fake rootfs in a
# temp dir via the ROOT override; never touches the host and never runs apt,
# update-grub or chroot.

setup() {
  export ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/etc/apt/sources.list.d"
  cp "$BATS_TEST_DIRNAME/fixtures/debian.sources" \
    "$ROOT/etc/apt/sources.list.d/debian.sources"
  export SOURCES_FILE="/etc/apt/sources.list.d/debian.sources"
  export SOURCES_FORMAT="deb822"
  export CLOUD_CFG="/etc/cloud/cloud.cfg.d/01_debian_cloud.cfg"
  export FAMILY="debian"
  export FAMILY_DIR="$BATS_TEST_DIRNAME/../scripts/family"
  source "$BATS_TEST_DIRNAME/../scripts/customize-rootfs.sh"
  # main() loads the family file in production; tests call individual functions,
  # so load it here the same way.
  load_family
}

@test "deb822 source drops deb-src types" {
  configure_apt_sources

  grep -q '^Types: deb$' "$ROOT$SOURCES_FILE"
  ! grep -q 'deb-src' "$ROOT$SOURCES_FILE"
}

@test "legacy source comments out deb-src lines" {
  mkdir -p "$ROOT/etc/apt"
  cp "$BATS_TEST_DIRNAME/fixtures/sources.list" "$ROOT/etc/apt/sources.list"
  export SOURCES_FILE="/etc/apt/sources.list"
  export SOURCES_FORMAT="legacy"

  configure_apt_sources

  ! grep -q '^deb-src' "$ROOT$SOURCES_FILE"
}

@test "cloud-init generate_mirrorlists is disabled" {
  mkdir -p "$ROOT/etc/cloud/cloud.cfg.d"
  cp "$BATS_TEST_DIRNAME/fixtures/cloud.cfg" \
    "$ROOT/etc/cloud/cloud.cfg.d/01_debian_cloud.cfg"
  export CLOUD_CFG="/etc/cloud/cloud.cfg.d/01_debian_cloud.cfg"

  configure_cloud_init

  grep -q 'generate_mirrorlists: false' "$ROOT$CLOUD_CFG"
}

@test "missing cloud-init config is a no-op" {
  configure_cloud_init
}

@test "ubuntu default user becomes root and is unlocked" {
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: false\nsystem_info:\n  default_user:\n    name: ubuntu\n    lock_passwd: True\n    gecos: Ubuntu\n' \
    > "$ROOT/etc/cloud/cloud.cfg"

  configure_cloud_cfg

  grep -q '^disable_root: false' "$ROOT/etc/cloud/cloud.cfg"
  grep -q 'name: root' "$ROOT/etc/cloud/cloud.cfg"
  ! grep -q 'name: ubuntu' "$ROOT/etc/cloud/cloud.cfg"
  grep -q 'lock_passwd: False' "$ROOT/etc/cloud/cloud.cfg"
}

@test "debian cloud.cfg keeps its default user" {
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: false\nsystem_info:\n  default_user:\n    name: debian\n    lock_passwd: True\n' \
    > "$ROOT/etc/cloud/cloud.cfg"

  configure_cloud_cfg

  grep -q 'name: debian' "$ROOT/etc/cloud/cloud.cfg"
}

# The nested form, not the deprecated top-level apt_preserve_sources_list which
# logs a warning on every boot and is scheduled for removal in cloud-init 27.1.
@test "apt preserve_sources_list uses the non-deprecated nested form" {
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: false\n' > "$ROOT/etc/cloud/cloud.cfg"

  configure_cloud_cfg

  local cfg="$ROOT/etc/cloud/cloud.cfg.d/99-pve-apt.cfg"
  grep -q '^apt:$' "$cfg"
  grep -q '^  preserve_sources_list: true$' "$cfg"
  ! grep -q 'apt_preserve_sources_list' "$cfg"
}

@test "missing /etc/cloud/cloud.cfg is a no-op" {
  configure_cloud_cfg
}

@test "first-login security notice is installed for pam_motd" {
  mkdir -p "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/default" \
    "$ROOT/etc/systemd/system/getty.target.wants" "$ROOT/etc/modules-load.d" "$ROOT/etc/sysctl.d"
  : > "$ROOT/etc/default/grub"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  configure_system

  # pam_motd reads /etc/motd.d/, and this directory overrides /run/motd.d and
  # /usr/lib/motd.d, so a file here reaches SSH and console logins alike.
  [ -f "$ROOT/etc/motd.d/99-pve-security" ]
  grep -q 'prohibit-password' "$ROOT/etc/motd.d/99-pve-security"
}

@test "password root login is enabled in sshd" {
  mkdir -p "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/default" \
    "$ROOT/etc/systemd/system/getty.target.wants" "$ROOT/etc/modules-load.d" "$ROOT/etc/sysctl.d"
  : > "$ROOT/etc/default/grub"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  configure_system

  grep -q '^PermitRootLogin yes$' "$ROOT/etc/ssh/sshd_config.d/99-pve-root-login.conf"
}

# --- family dispatch --------------------------------------------------------

@test "the debian family is loaded and provides every hook main() calls" {
  for hook in family_install_packages family_configure_sources family_update_bootloader \
    family_ssh_unit family_configure_ntp family_relabel family_default_user_alias; do
    [ "$(type -t "$hook")" = "function" ] || {
      echo "missing hook: $hook"
      return 1
    }
  done
}

@test "an unknown family fails loudly instead of silently skipping steps" {
  FAMILY=nosuchfamily run load_family
  [ "$status" -ne 0 ]
  [[ "$output" == *"no family implementation for 'nosuchfamily'"* ]]
}

# The rename target is per family; getting it wrong means PVE's cipassword lands
# on a user nobody logs in as, which fails only at login time on a real guest.
@test "debian renames the ubuntu default user" {
  [ "$(family_default_user_alias)" = "ubuntu" ]
}

@test "debian does not write an apt drop-in for non-debian families" {
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"
  FAMILY=rhel

  configure_cloud_cfg

  [ ! -f "$ROOT/etc/cloud/cloud.cfg.d/99-pve-apt.cfg" ]
}

# CentOS 7 ships no Include line, so without this the PermitRootLogin drop-in is
# inert and root password login silently never works.
@test "sshd_config gains an Include for the drop-in directory when absent" {
  mkdir -p "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/default" \
    "$ROOT/etc/systemd/system/getty.target.wants" "$ROOT/etc/modules-load.d" "$ROOT/etc/sysctl.d"
  : > "$ROOT/etc/default/grub"
  printf 'PasswordAuthentication yes\n' > "$ROOT/etc/ssh/sshd_config"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  configure_system

  grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf$' "$ROOT/etc/ssh/sshd_config"
}

@test "an existing Include line is not duplicated" {
  mkdir -p "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/default" \
    "$ROOT/etc/systemd/system/getty.target.wants" "$ROOT/etc/modules-load.d" "$ROOT/etc/sysctl.d"
  : > "$ROOT/etc/default/grub"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$ROOT/etc/ssh/sshd_config"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  configure_system

  [ "$(grep -c '^Include /etc/ssh/sshd_config.d' "$ROOT/etc/ssh/sshd_config")" -eq 1 ]
}

# --- RHEL family ------------------------------------------------------------

rhel_setup() {
  export FAMILY=rhel
  export FAMILY_DIR="$BATS_TEST_DIRNAME/../scripts/family"
  load_family
  mkdir -p "$ROOT/etc/ssh/sshd_config.d" "$ROOT/etc/default" \
    "$ROOT/etc/systemd/system/getty.target.wants" "$ROOT/etc/modules-load.d" \
    "$ROOT/etc/sysctl.d" "$ROOT/etc/ssh"
  : > "$ROOT/etc/default/grub"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$ROOT/etc/ssh/sshd_config"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"
}

@test "the rhel family implements every hook main() calls" {
  rhel_setup
  for hook in family_install_packages family_configure_sources family_update_bootloader \
    family_ssh_unit family_configure_ntp family_relabel family_default_user_alias; do
    [ "$(type -t "$hook")" = "function" ] || { echo "missing hook: $hook"; return 1; }
  done
}

# The unit is sshd, not ssh, and the motd the operator reads names it.
@test "rhel names the sshd unit, not ssh" {
  rhel_setup
  [ "$(family_ssh_unit)" = "sshd" ]
}

@test "the security notice names this family's ssh unit" {
  rhel_setup
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg" 2>/dev/null || {
    mkdir -p "$ROOT/etc/cloud"; printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"; }

  configure_system

  grep -q 'systemctl reload sshd' "$ROOT/etc/motd.d/99-pve-security"
  ! grep -q 'systemctl reload ssh$' "$ROOT/etc/motd.d/99-pve-security"
}

# Rocky's default user is rocky; CentOS 7's is centos. Both must become root or
# PVE's cipassword lands somewhere nobody logs in as.
@test "rhel renames rocky to root" {
  rhel_setup
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: true\nssh_pwauth: false\nsystem_info:\n  default_user:\n    name: rocky\n    lock_passwd: True\n' \
    > "$ROOT/etc/cloud/cloud.cfg"

  configure_cloud_cfg

  grep -q 'name: root' "$ROOT/etc/cloud/cloud.cfg"
  grep -q 'lock_passwd: False' "$ROOT/etc/cloud/cloud.cfg"
  ! grep -q 'name: rocky' "$ROOT/etc/cloud/cloud.cfg"
}

@test "rhel renames centos to root" {
  rhel_setup
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: 1\nssh_pwauth:   0\nsystem_info:\n  default_user:\n    name: centos\n    lock_passwd: true\n' \
    > "$ROOT/etc/cloud/cloud.cfg"

  configure_cloud_cfg

  grep -q 'name: root' "$ROOT/etc/cloud/cloud.cfg"
  grep -q 'lock_passwd: False' "$ROOT/etc/cloud/cloud.cfg"
  ! grep -q 'name: centos' "$ROOT/etc/cloud/cloud.cfg"
}

# RHEL family uses chrony, not timesyncd, which does not exist on those images.
@test "rhel writes chrony config and not timesyncd" {
  rhel_setup
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"
  printf 'pool 2.rocky.pool.ntp.org iburst\n' > "$ROOT/etc/chrony.conf"

  configure_system

  grep -q 'pool time.apple.com iburst' "$ROOT/etc/chrony.conf"
  [ ! -s "$ROOT/etc/systemd/timesyncd.conf" ]
}

@test "rhel does not write the bbr module list" {
  rhel_setup
  mkdir -p "$ROOT/etc/cloud"
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"

  configure_system

  # tcp_bbr does not exist on CentOS 7's 3.10 kernel and modules-load.d is not
  # read by its systemd, so the file would be a lie either way.
  [ ! -f "$ROOT/etc/modules-load.d/bbr.conf" ]
}

@test "debian does write the bbr module list" {
  mkdir -p "$ROOT/etc/cloud" "$ROOT/etc/default" \
    "$ROOT/etc/systemd/system/getty.target.wants" "$ROOT/etc/modules-load.d" "$ROOT/etc/sysctl.d" "$ROOT/etc/ssh"
  : > "$ROOT/etc/default/grub"
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$ROOT/etc/ssh/sshd_config"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  configure_system

  grep -q '^tcp_bbr$' "$ROOT/etc/modules-load.d/bbr.conf"
}


@test "rhel relabel is a no-op when the image has no SELinux policy" {
  rhel_setup

  run family_relabel

  [ "$status" -eq 0 ]
  [[ "$output" == *"no SELinux file_contexts"* ]]
}

# --- robustness: directories the image may not ship -------------------------

# An `install` into a directory that does not exist aborts the build, and the
# RHEL family does not necessarily ship every /etc subdirectory the Debian family
# does. Creating each target directory makes the write independent of the image.
@test "sysctl and module dirs are created before writing into them" {
  mkdir -p "$ROOT/etc/cloud" "$ROOT/etc/ssh"
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$ROOT/etc/ssh/sshd_config"
  # deliberately do NOT pre-create /etc/sysctl.d, /etc/modules-load.d or the
  # getty wants dir
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  run configure_system

  [ "$status" -eq 0 ]
  [ -f "$ROOT/etc/sysctl.d/99-pve-cloud-tuning.conf" ]
  [ -f "$ROOT/etc/modules-load.d/bbr.conf" ]
  [ -L "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyS1.service" ]
}

@test "a missing /etc/default/grub is a warning, not a failure" {
  mkdir -p "$ROOT/etc/cloud" "$ROOT/etc/ssh" "$ROOT/etc/sysctl.d"
  printf 'disable_root: true\n' > "$ROOT/etc/cloud/cloud.cfg"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\n' > "$ROOT/etc/ssh/sshd_config"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  run configure_system

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping the os-prober tweak"* ]]
}

# --- BLS entries must not reference a build-time PARTUUID --------------------

# The shipped Rocky image booted into a dracut emergency shell:
#   /dev/disk/by-partuuid/580b80dc-... does not exist
# because dnf's kernel-install wrote BLS entries using the PARTUUID the *build*
# kernel saw, which the finished image does not have. GRUB boots the newest
# entry, so the image was unbootable while every kernel/initrd count was correct.
bls_setup() {
  rhel_setup
  mkdir -p "$ROOT/etc" "$ROOT/boot/loader/entries"
  printf 'UUID=5c547c15-e655-458f-bc8e-b2877acc2676 / xfs defaults 0 1\n' > "$ROOT/etc/fstab"
  # grub2-mkconfig does not exist in the test environment
  grub2-mkconfig() { :; }
}

@test "a PARTUUID root reference in a BLS entry is rewritten to the fstab UUID" {
  bls_setup
  printf 'options root=PARTUUID=580b80dc-f54b-4d06-9389-f702fab8bd92 ro\n' \
    > "$ROOT/boot/loader/entries/entry.conf"

  run family_update_bootloader

  [ "$status" -eq 0 ]
  grep -q 'root=UUID=5c547c15-e655-458f-bc8e-b2877acc2676' "$ROOT/boot/loader/entries/entry.conf"
  ! grep -q 'PARTUUID' "$ROOT/boot/loader/entries/entry.conf"
}

@test "an already-correct UUID root reference is left alone" {
  bls_setup
  printf 'options root=UUID=5c547c15-e655-458f-bc8e-b2877acc2676 ro\n' \
    > "$ROOT/boot/loader/entries/entry.conf"

  run family_update_bootloader

  [ "$status" -eq 0 ]
  [ "$(grep -c 'root=UUID=5c547c15' "$ROOT/boot/loader/entries/entry.conf")" -eq 1 ]
}

@test "several entries are all rewritten" {
  bls_setup
  printf 'options root=PARTUUID=aaaa-1 ro\n' > "$ROOT/boot/loader/entries/a.conf"
  printf 'options root=PARTUUID=bbbb-2 ro\n' > "$ROOT/boot/loader/entries/b.conf"

  run family_update_bootloader

  [ "$status" -eq 0 ]
  ! grep -rq 'PARTUUID' "$ROOT/boot/loader/entries/"
}

@test "a missing fstab root entry warns and does not touch the entries" {
  bls_setup
  printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "$ROOT/etc/fstab"
  printf 'options root=PARTUUID=580b80dc ro\n' > "$ROOT/boot/loader/entries/entry.conf"

  run family_update_bootloader

  [[ "$output" == *"leaving BLS entries alone"* ]]
}

@test "images without BLS entries are unaffected" {
  bls_setup
  rm -rf "$ROOT/boot/loader/entries"

  run family_update_bootloader

  [ "$status" -eq 0 ]
  [[ "$output" == *"No BLS entries to check"* ]]
}

# --- CentOS 7 specifics ------------------------------------------------------

# mirrorlist.centos.org no longer resolves, so the stock repos are dead and the
# build cannot install anything until they are pointed at the vault. Verified
# against the real vault earlier: yum -y update reaches "Complete!" with these.
@test "centos 7 repositories are rewritten to the vault" {
  rhel_setup
  export ROOT="$BATS_TEST_TMPDIR/root"
  export SOURCES_FILE=/etc/yum.repos.d/CentOS-Base.repo
  mkdir -p "$ROOT/etc/yum.repos.d"
  printf '[base]\nmirrorlist=http://mirrorlist.centos.org/?release=7&repo=os\nenabled=1\n' \
    > "$ROOT/etc/yum.repos.d/CentOS-Base.repo"

  family_configure_sources

  local v="$ROOT/etc/yum.repos.d/99-pve-vault.repo"
  [ -f "$v" ]
  grep -q 'baseurl=http://vault.centos.org/7.9.2009/os/\$basearch/' "$v"
  grep -q 'baseurl=http://vault.centos.org/7.9.2009/updates/\$basearch/' "$v"
  grep -q 'baseurl=http://vault.centos.org/7.9.2009/extras/\$basearch/' "$v"
  # the dead mirrorlist-backed repos must be off, or yum still tries them
  grep -q '^enabled=0' "$ROOT/etc/yum.repos.d/CentOS-Base.repo"
  ! grep -q '^mirrorlist=http' "$ROOT/etc/yum.repos.d/CentOS-Base.repo"
}

# Rocky's repos are live and must NOT be touched.
@test "rocky repositories are left alone" {
  rhel_setup
  export SOURCES_FILE=/etc/yum.repos.d/rocky.repo
  mkdir -p "$ROOT/etc/yum.repos.d"
  printf '[baseos]\nmirrorlist=https://mirrors.rockylinux.org/mirrorlist\nenabled=1\n' \
    > "$ROOT/etc/yum.repos.d/rocky.repo"

  family_configure_sources

  [ ! -f "$ROOT/etc/yum.repos.d/99-pve-vault.repo" ]
  grep -q '^enabled=1' "$ROOT/etc/yum.repos.d/rocky.repo"
}

@test "an end-of-life notice is written for centos 7" {
  rhel_setup
  export SOURCES_FILE=/etc/yum.repos.d/CentOS-Base.repo

  family_eol_notice

  local n="$ROOT/etc/motd.d/98-pve-eol"
  [ -f "$n" ]
  grep -q '2024-06-30' "$n"
  grep -q 'never receive another security update' "$n"
}

@test "no end-of-life notice for rocky" {
  rhel_setup
  export SOURCES_FILE=/etc/yum.repos.d/rocky.repo

  family_eol_notice

  [ ! -f "$ROOT/etc/motd.d/98-pve-eol" ]
}

# CentOS 7's pam_motd predates motd.d, so a notice only in motd.d would never be
# shown. Every notice must be mirrored into /etc/motd in that case.
@test "all motd.d notices are mirrored into /etc/motd when motd.d is unsupported" {
  rhel_setup
  export SOURCES_FILE=/etc/yum.repos.d/CentOS-Base.repo
  mkdir -p "$ROOT/etc/cloud" "$ROOT/etc/sysctl.d"
  printf 'disable_root: 1\n' > "$ROOT/etc/cloud/cloud.cfg"
  printf 'PermitRootLogin yes\n' > "$ROOT/etc/ssh/sshd_config"
  # no motd.d reference in pam => the fallback path
  mkdir -p "$ROOT/etc/pam.d"
  printf 'session optional pam_motd.so motd=/run/motd.dynamic\n' > "$ROOT/etc/pam.d/sshd"
  export SYSCTL_FILE="$BATS_TEST_DIRNAME/fixtures/sysctl.conf"

  configure_system

  grep -q 'CentOS 7 reached end of life' "$ROOT/etc/motd"
  grep -q 'password-based root SSH login' "$ROOT/etc/motd"
}

# Every family must implement the hooks the shared script calls.
@test "both families implement family_eol_notice" {
  for fam in debian rhel; do
    FAMILY="$fam"
    FAMILY_DIR="$BATS_TEST_DIRNAME/../scripts/family"
    load_family
    [ "$(type -t family_eol_notice)" = "function" ] || { echo "$fam lacks it"; return 1; }
  done
}

# --- grub platform must match the image's firmware --------------------------

# Measured failure: a BIOS-only CentOS 7 image was built with `grub2-mkconfig`,
# which detected the *runner's* platform and emitted linuxefi/initrdefi. BIOS GRUB
# cannot run those, so the image failed to boot with
#   error: can't find command `linuxefi'
# while the stock upstream image correctly used linux16/initrd16.
#
# Each config file is pinned to the firmware that will read it, and the two are
# pinned independently of FIRMWARE: a CentOS 7 image that gets an ESP keeps its MBR
# path as well, so its FIRMWARE is efi while its BIOS config still has to be
# written and pinned to BIOS command names.
grub_setup() {
  rhel_setup
  mkdir -p "$ROOT/boot/grub2"
  # grub2-mkconfig is not available in the test environment; it leaves the file as
  # the "already generated" one, which is what the rewrite step then fixes.
  grub2-mkconfig() { :; }
}

@test "EFI-only commands are rewritten for the BIOS grub.cfg" {
  grub_setup
  printf 'linuxefi /vmlinuz-x\ninitrdefi /initramfs-x.img\n' > "$ROOT/boot/grub2/grub.cfg"

  run grub2_mkconfig_bios

  [ "$status" -eq 0 ]
  grep -q '^linux16 /vmlinuz-x' "$ROOT/boot/grub2/grub.cfg"
  grep -q '^initrd16 /initramfs-x.img' "$ROOT/boot/grub2/grub.cfg"
  ! grep -q 'linuxefi\|initrdefi' "$ROOT/boot/grub2/grub.cfg"
}

@test "a BIOS config with no EFI-only commands is left alone" {
  grub_setup
  printf 'linux16 /vmlinuz-x\ninitrd16 /initramfs-x.img\n' > "$ROOT/boot/grub2/grub.cfg"

  run grub2_mkconfig_bios

  [ "$status" -eq 0 ]
  [[ "$output" != *"Rewrote EFI-only"* ]]
  grep -q '^linux16 ' "$ROOT/boot/grub2/grub.cfg"
}

# The guard that stops a non-booting image shipping, the way the PARTUUID one did.
@test "a BIOS config still holding EFI commands is rejected" {
  grub_setup
  printf 'linuxefi /vmlinuz-x\n' > "$ROOT/boot/grub2/grub.cfg"
  # make the rewrite a no-op so the guard is what fails the function
  run bash -c '
    source "'"$BATS_TEST_DIRNAME"'/../scripts/family/rhel.sh"
    root_path(){ printf "%s%s\n" "$ROOT" "$1"; }
    grub2-mkconfig(){ :; }
    sed(){ :; }
    grub2_mkconfig_bios'
  [ "$status" -ne 0 ]
  [[ "$output" == *"EFI-only commands on a BIOS image"* ]]
}

# The BIOS config is pinned to BIOS regardless of what FIRMWARE says, because on a
# dual-firmware image FIRMWARE names the firmware the *boot test* uses, not the one
# that reads /boot/grub2/grub.cfg. Getting this backwards is the same shipped-image
# failure as above, only reachable via the efi_esp path.
@test "the BIOS config is pinned to BIOS even when FIRMWARE is efi" {
  grub_setup
  export FIRMWARE=efi
  printf 'linuxefi /vmlinuz-x\ninitrdefi /initramfs-x.img\n' > "$ROOT/boot/grub2/grub.cfg"

  run grub2_mkconfig_bios

  [ "$status" -eq 0 ]
  grep -q '^linux16 /vmlinuz-x' "$ROOT/boot/grub2/grub.cfg"
  ! grep -q 'linuxefi\|initrdefi' "$ROOT/boot/grub2/grub.cfg"
}

# The mirror image of the above: the ESP config is pinned to EFI no matter what
# FIRMWARE says, since EFI GRUB is what reads it either way.
@test "the ESP config is rewritten to EFI command names" {
  grub_setup
  mkdir -p "$ROOT/boot/efi/EFI/centos"
  local cfg="$ROOT/boot/efi/EFI/centos/grub.cfg"
  printf 'linux16 /vmlinuz-x\ninitrd16 /initramfs-x.img\n' > "$cfg"

  run grub2_mkconfig_efi "$cfg"

  [ "$status" -eq 0 ]
  grep -q '^linuxefi /vmlinuz-x' "$cfg"
  grep -q '^initrdefi /initramfs-x.img' "$cfg"
  ! grep -q 'linux16\|initrd16' "$cfg"
}

# Rocky 9/10 emit no command name at all (their entries are a blscfg call which
# picks the right one at runtime), so the ESP check must accept that shape rather
# than demand linuxefi.
@test "the ESP config accepts a blscfg-only config such as Rocky's" {
  grub_setup
  local cfg="$ROOT/boot/efi/EFI/centos/grub.cfg"
  mkdir -p "$(dirname "$cfg")"
  printf 'insmod blscfg\nblscfg\n' > "$cfg"

  run grub2_mkconfig_efi "$cfg"

  [ "$status" -eq 0 ]
}

# A config with no kernel entry and no blscfg would never boot while passing every
# other check, so it is rejected outright.
@test "the ESP config with no kernel entry and no blscfg is rejected" {
  grub_setup
  local cfg="$ROOT/boot/efi/EFI/centos/grub.cfg"
  mkdir -p "$(dirname "$cfg")"
  printf 'set timeout=5\n' > "$cfg"

  run grub2_mkconfig_efi "$cfg"

  [ "$status" -ne 0 ]
  [[ "$output" == *"no kernel entry and no blscfg"* ]]
}

# The ESP config must not be generated at all when the pipeline did not create the
# ESP: on Rocky the file already exists and works, and rewriting it would replace
# the distro's own three-line pointer with a generated config. The guard is
# ESP_UUID, which customize-image.sh only sets on the runs that created the ESP.
@test "no ESP config is written when the pipeline did not create the ESP" {
  grub_setup
  unset ESP_UUID
  # makes the hook's write path fail loudly if it is ever reached
  mkdir -p "$ROOT/boot/efi/EFI/centos"
  grub2_mkconfig_efi() { echo "reached the ESP writer" >&2; return 1; }

  run family_esp_write_config

  [ "$status" -eq 0 ]
  [[ "$output" != *"ESP writer"* ]]
}

# --- SELinux must not prevent the first boot ---------------------------------

# Measured on Rocky 10: with unlabeled files and SELinux enforcing, systemd 257
# refuses to start at all --
#   systemd[1]: Failed to allocate manager object: Permission denied
# -- and the image hangs with no login prompt. Rocky 9's older systemd tolerated
# it, so this only surfaced when 10 was added. Build-time relabelling is
# impossible on the runner (security.selinux writes return EPERM even as root
# with all capabilities), so the image relabels on first boot and must therefore
# be permissive during that boot.
selinux_setup() {
  rhel_setup
  mkdir -p "$ROOT/etc/selinux/targeted/contexts/files" "$ROOT/etc/selinux"
  : > "$ROOT/etc/selinux/targeted/contexts/files/file_contexts"
  printf 'SELINUX=enforcing\nSELINUXTYPE=targeted\n' > "$ROOT/etc/selinux/config"
}

@test "an enforcing image is made permissive with a first-boot relabel" {
  selinux_setup
  export SOURCES_FILE=/etc/yum.repos.d/rocky.repo

  run family_relabel

  [ "$status" -eq 0 ]
  grep -q '^SELINUX=permissive' "$ROOT/etc/selinux/config"
  [ -f "$ROOT/.autorelabel" ]
  grep -q '^-F$' "$ROOT/.autorelabel"
}

# The delivered VM must end up enforcing again, or the security posture is
# silently downgraded for the image's whole life.
@test "a unit restores enforcing after the relabel" {
  selinux_setup
  export SOURCES_FILE=/etc/yum.repos.d/rocky.repo

  family_relabel

  local u="$ROOT/etc/systemd/system/99-pve-restore-selinux.service"
  [ -f "$u" ]
  grep -q 'SELINUX=enforcing' "$u"
  grep -q 'rm -f /.autorelabel' "$u"
  [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/99-pve-restore-selinux.service" ]
}

@test "a non-enforcing image only gets the relabel marker" {
  selinux_setup
  export SOURCES_FILE=/etc/yum.repos.d/rocky.repo
  printf 'SELINUX=disabled\n' > "$ROOT/etc/selinux/config"

  run family_relabel

  [ "$status" -eq 0 ]
  grep -q '^SELINUX=disabled' "$ROOT/etc/selinux/config"
  [ -f "$ROOT/.autorelabel" ]
  [[ "$output" == *"not enforcing"* ]]
}

@test "an image with no SELinux policy is left alone" {
  rhel_setup
  export SOURCES_FILE=/etc/yum.repos.d/rocky.repo

  run family_relabel

  [ "$status" -eq 0 ]
  [[ "$output" == *"no SELinux file_contexts"* ]]
  [ ! -f "$ROOT/.autorelabel" ]
}

# --- login notices must actually be displayed --------------------------------

# RHEL-family images never call pam_motd: /etc/pam.d/sshd and /etc/pam.d/login
# carry no motd line, so a notice in /etc/motd or /etc/motd.d is never shown. For
# CentOS 7 that defeats the point of the end-of-life warning.
@test "rhel adds the missing pam_motd line" {
  rhel_setup
  mkdir -p "$ROOT/etc/pam.d"
  printf 'session    required     pam_loginuid.so\nsession    include      password-auth\n' \
    > "$ROOT/etc/pam.d/sshd"
  printf 'session    required     pam_selinux.so open\n' > "$ROOT/etc/pam.d/login"

  run family_enable_motd

  [ "$status" -eq 0 ]
  grep -q 'pam_motd.so' "$ROOT/etc/pam.d/sshd"
  grep -q 'pam_motd.so' "$ROOT/etc/pam.d/login"
  [[ "$output" == *"2 pam config(s)"* ]]
}

@test "an existing pam_motd line is not duplicated" {
  rhel_setup
  mkdir -p "$ROOT/etc/pam.d"
  printf 'session    optional     pam_motd.so motd=/run/motd.dynamic\n' > "$ROOT/etc/pam.d/sshd"
  printf 'session    required     pam_loginuid.so\n' > "$ROOT/etc/pam.d/login"

  run family_enable_motd

  [ "$status" -eq 0 ]
  [ "$(grep -c 'pam_motd' "$ROOT/etc/pam.d/sshd")" -eq 1 ]
  grep -q 'pam_motd' "$ROOT/etc/pam.d/login"
}

@test "rhel tolerates missing pam files" {
  rhel_setup

  run family_enable_motd

  [ "$status" -eq 0 ]
}

@test "both families implement family_enable_motd" {
  for fam in debian rhel; do
    FAMILY="$fam"
    FAMILY_DIR="$BATS_TEST_DIRNAME/../scripts/family"
    load_family
    [ "$(type -t family_enable_motd)" = "function" ] || { echo "$fam lacks it"; return 1; }
  done
}
