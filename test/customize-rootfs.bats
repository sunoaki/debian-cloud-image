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

# Build-time relabel is impossible on the runner (measured: security.selinux
# writes return EPERM even as uid 0 with all capabilities, because the kernel has
# SELinux compiled in but not enabled). The image therefore carries
# /.autorelabel and relabels on first boot instead.
@test "rhel defers the SELinux relabel to first boot" {
  rhel_setup
  mkdir -p "$ROOT/etc/selinux/targeted/contexts/files"
  : > "$ROOT/etc/selinux/targeted/contexts/files/file_contexts"

  run family_relabel

  [ "$status" -eq 0 ]
  [ -f "$ROOT/.autorelabel" ]
  grep -q '^-F$' "$ROOT/.autorelabel"
  [[ "$output" == *"takes minutes"* ]]
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
