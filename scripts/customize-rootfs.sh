#!/usr/bin/env bash
# customize-rootfs.sh
# Runs INSIDE the target rootfs (via chroot) to customize a cloud image for PVE.
# Functionized so the pure-file edits can be unit-tested with bats (ROOT override);
# package installs and update-grub only run in production (ROOT=/).
set -Eeuo pipefail

ROOT="${ROOT:-/}"
SOURCES_FILE="${SOURCES_FILE:?SOURCES_FILE is required}"
CLOUD_CFG="${CLOUD_CFG:?CLOUD_CFG is required}"
SOURCES_FORMAT="${SOURCES_FORMAT:?SOURCES_FORMAT is required}"
PACKAGES_FILE="${PACKAGES_FILE:-/tmp/cloud-image-packages.txt}"
SYSCTL_FILE="${SYSCTL_FILE:-/tmp/cloud-image-sysctl.conf}"

root_path() {
  printf '%s%s\n' "$ROOT" "$1"
}

configure_apt_sources() {
  local file
  file="$(root_path "$SOURCES_FILE")"
  if [ "$SOURCES_FORMAT" = "legacy" ]; then
    sed -i 's|^deb-src|# deb-src|' "$file"
  else
    sed -i 's|Types: deb deb-src|Types: deb|g' "$file"
  fi
}

configure_cloud_init() {
  local cfg
  cfg="$(root_path "$CLOUD_CFG")"
  # cloud-init: do not regenerate apt sources at boot (file may be absent on Ubuntu)
  [ -f "$cfg" ] || return 0
  sed -i 's|generate_mirrorlists: true|generate_mirrorlists: false|g' "$cfg"
}

install_packages() {
  local packages
  packages="$(grep -Ev '^\s*(#|$)' "$PACKAGES_FILE" | xargs)"
  [ -n "$packages" ] || { echo "no packages in $PACKAGES_FILE" >&2; return 1; }

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y upgrade
  # shellcheck disable=SC2086 # packages list is intended to word-split
  apt-get -y install $packages
  apt-get -y autoremove --purge
}

configure_system() {
  # Timezone: Asia/Hong_Kong
  ln -sf /usr/share/zoneinfo/Asia/Hong_Kong "$(root_path /etc/localtime)"
  echo "Asia/Hong_Kong" > "$(root_path /etc/timezone)"

  # GRUB: disable os-prober (loopback detection breaks booting)
  local grub_cfg
  grub_cfg="$(root_path /etc/default/grub)"
  if grep -q '^GRUB_DISABLE_OS_PROBER' "$grub_cfg"; then
    sed -i 's|^#\?GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=true|' "$grub_cfg"
  else
    printf '# disables OS prober to avoid loopback detection which breaks booting\nGRUB_DISABLE_OS_PROBER=true\n' >> "$grub_cfg"
  fi
  # update-grub runs grub-mkconfig; needs /proc mounted and grub tools present.
  # Only meaningful in production (chroot). In tests ROOT!=/ so skip.
  if [ "$ROOT" = "/" ]; then
    update-grub
  fi

  # Serial console on ttyS1 (default PVE serial terminal)
  ln -sf /lib/systemd/system/serial-getty@.service \
    "$(root_path /etc/systemd/system/getty.target.wants/serial-getty@ttyS1.service)"

  # NTP
  printf '\nNTP=time.apple.com time.windows.com\n' >> "$(root_path /etc/systemd/timesyncd.conf)"

  # Root login by password (PVE cloud-init defaults: root user + ssh password).
  local cloud_cfg
  cloud_cfg="$(root_path /etc/cloud/cloud.cfg)"
  sed -i 's|^disable_root:.*|disable_root: false|' "$cloud_cfg"
  grep -q '^disable_root:' "$cloud_cfg" || echo 'disable_root: false' >> "$cloud_cfg"
  sed -i 's|^ssh_pwauth:.*|ssh_pwauth: true|' "$cloud_cfg"
  grep -q '^ssh_pwauth:' "$cloud_cfg" || echo 'ssh_pwauth: true' >> "$cloud_cfg"

  printf 'PermitRootLogin yes\n' > "$(root_path /etc/ssh/sshd_config.d/99-pve-root-login.conf)"

  # Root prompt (PVE default login is root). Single-quoted so \$ renders
  # as '#' for root; printf avoids nested-heredoc indentation issues.
  touch "$(root_path /root/.bashrc)"
  sed -i '/^PS1=/d' "$(root_path /root/.bashrc)"
  printf "PS1='%s'\n" '\[\033[01;31m\]\u\[\033[01;33m\]@\[\033[01;36m\]\h \[\033[01;33m\]\w \[\033[01;35m\]\$ \[\033[00m\]' >> "$(root_path /root/.bashrc)"
  if [ ! -f "$(root_path /root/.profile)" ]; then
    # shellcheck disable=SC2016 # $BASH_VERSION must stay literal in .profile
    echo 'if [ -n "$BASH_VERSION" ]; then . ~/.bashrc; fi' > "$(root_path /root/.profile)"
  elif ! grep -q 'bashrc' "$(root_path /root/.profile)"; then
    # shellcheck disable=SC2016 # $BASH_VERSION must stay literal in .profile
    echo 'if [ -n "$BASH_VERSION" ]; then . ~/.bashrc; fi' >> "$(root_path /root/.profile)"
  fi

  # BBR + kernel tuning. sysctl values live in the repo as a template file
  # (config/cloud-image-sysctl.conf) so they are easy to review and edit.
  printf 'tcp_bbr\n' > "$(root_path /etc/modules-load.d/bbr.conf)"
  install -m 0644 "$SYSCTL_FILE" "$(root_path /etc/sysctl.d/99-pve-cloud-tuning.conf)"
}

cleanup_rootfs() {
  rm -f "$(root_path /var/log)"/*.log
  local tmpdir
  tmpdir="$(root_path /tmp)"
  rm -rf "${tmpdir:?}/"*
  truncate -s 0 "$(root_path /etc/machine-id)"
}

main() {
  configure_apt_sources
  configure_cloud_init
  install_packages
  configure_system
  cleanup_rootfs
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
