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

# PVE cloud-init applies cipassword to the *default* user, so root must be
# the default user (Ubuntu ships "ubuntu" with root locked) and unlocked,
# otherwise root password login never works.
#
# Two different files are in play and they are not interchangeable:
#   $CLOUD_CFG (from config/images.yaml) - the per-distro vendor drop-in,
#     e.g. .../01_debian_cloud.cfg or .../99-fake_cloud.cfg, handled above.
#   /etc/cloud/cloud.cfg - the main config holding system_info.default_user;
#     it has no matrix entry because it is at the same path on every distro.
configure_cloud_cfg() {
  local cloud_cfg
  cloud_cfg="$(root_path /etc/cloud/cloud.cfg)"
  if [ ! -f "$cloud_cfg" ]; then
    echo "WARN: /etc/cloud/cloud.cfg missing, skipping cloud.cfg tweaks" >&2
    return 0
  fi
  sed -i 's|^disable_root:.*|disable_root: false|' "$cloud_cfg"
  grep -q '^disable_root:' "$cloud_cfg" || echo 'disable_root: false' >> "$cloud_cfg"
  sed -i 's|^ssh_pwauth:.*|ssh_pwauth: true|' "$cloud_cfg"
  grep -q '^ssh_pwauth:' "$cloud_cfg" || echo 'ssh_pwauth: true' >> "$cloud_cfg"

  if grep -q '^[[:space:]]*name: ubuntu' "$cloud_cfg"; then
    sed -i 's|^\([[:space:]]*\)name: ubuntu$|\1name: root|' "$cloud_cfg"
    sed -i 's|^\([[:space:]]*\)lock_passwd: True$|\1lock_passwd: False|' "$cloud_cfg"
  fi

  # Keep the apt sources that PVE swaps in after download: without this Ubuntu
  # cloud-init regenerates sources.list(.d) on first boot and clobbers the
  # xtom HK mirror. Use the nested form: the older top-level
  # apt_preserve_sources_list is still accepted (cc_apt_configure converts it)
  # but logs a deprecation warning on every boot and is due for removal, which a
  # live guest confirmed:
  #   The following config key(s): ['apt_preserve_sources_list'] is deprecated
  #   in 22.1 and scheduled to be removed in 27.1.
  mkdir -p "$(root_path /etc/cloud/cloud.cfg.d)"
  printf 'apt:\n  preserve_sources_list: true\n' > "$(root_path /etc/cloud/cloud.cfg.d/99-pve-apt.cfg)"
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

  configure_cloud_cfg
  printf 'PermitRootLogin yes\n' > "$(root_path /etc/ssh/sshd_config.d/99-pve-root-login.conf)"

  # First-login warning for password-based root login. pam_motd shows the files
  # in /etc/motd.d/ (and that directory overrides /run/motd.d and
  # /usr/lib/motd.d), so this reaches both SSH and console logins.
  mkdir -p "$(root_path /etc/motd.d)"
  cat > "$(root_path /etc/motd.d/99-pve-security)" <<'MOTD'
This image ships with password-based root SSH login enabled and its images are
published publicly. Keep this host on a controlled network (private subnet or a
security group restricted by source IP), and switch to key-based authentication
before exposing it. To disable password login:

    printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/99-pve-root-login.conf
    systemctl reload ssh
MOTD

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
