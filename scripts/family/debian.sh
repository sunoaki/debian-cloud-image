#!/usr/bin/env bash
# family/debian.sh
# Debian-family (Debian, Ubuntu) implementations of the hooks that differ
# between distro families. customize-rootfs.sh selects one family file from
# config/images.yaml's `family` field and calls these by name; the shared steps
# (timezone, motd, sysctl, cleanup, cloud-init) live in customize-rootfs.sh and
# are not repeated here.
#
# Every function receives ROOT and the environment variables customize-rootfs.sh
# has already validated, and uses root_path() for paths so the ROOT override
# used by the bats tests keeps working.

family_install_packages() {
  local packages="$1"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  # shellcheck disable=SC2086 # packages list is intended to word-split
  apt-get -y install $packages
  apt-get -y autoremove --purge
}

# Strip deb-src entries so the image cannot accidentally build from source.
# Two on-disk shapes exist: deb822 (.sources) on Debian 12+/Ubuntu 24+, and the
# legacy one-line format on Ubuntu 22.04.
family_configure_sources() {
  local file
  file="$(root_path "$SOURCES_FILE")"
  [ -f "$file" ] || return 0
  if [ "$SOURCES_FORMAT" = "legacy" ]; then
    sed -i 's|^deb-src|# deb-src|' "$file"
  else
    sed -i 's|Types: deb deb-src|Types: deb|g' "$file"
  fi
}

# Debian and Ubuntu use update-grub, which is a wrapper around grub-mkconfig with
# the distro's own output path.
family_update_bootloader() {
  update-grub
}

# The ssh unit is called ssh on Debian and sshd on RHEL.
family_ssh_unit() {
  printf 'ssh\n'
}

# timesyncd is present on both Debian and Ubuntu.
family_configure_ntp() {
  printf '\nNTP=time.apple.com time.windows.com\n' >> "$(root_path /etc/systemd/timesyncd.conf)"
}

# Nothing to do: Debian and Ubuntu do not use SELinux labels.
family_relabel() {
  return 0
}

# The default user that PVE's cloud-init cipassword is applied to must be root.
# Ubuntu ships "ubuntu" with root locked; Debian's images already have no
# conflicting entry, so only Ubuntu's needs renaming. distro_release_with_root()
# in customize-rootfs.sh applies this to /etc/cloud/cloud.cfg.
family_default_user_alias() {
  printf 'ubuntu\n'
}

# No end-of-life notices for this family: every entry it serves is a supported
# release. Present as an explicit no-op so the hook contract is uniform and
# customize-rootfs.sh can call it unconditionally.
family_eol_notice() {
  return 0
}

# Debian and Ubuntu already call pam_motd, so the shared motd work suffices.
family_enable_motd() {
  return 0
}

# Debian and Ubuntu images already ship an ESP with the bootloader on it, so there
# is nothing to configure: the two steps in configure_system are no-ops here.
family_esp_configure() {
  return 0
}

family_esp_write_config() {
  return 0
}
