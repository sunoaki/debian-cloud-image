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
