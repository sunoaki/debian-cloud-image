#!/usr/bin/env bash
# customize-rootfs.sh
# Runs INSIDE the target rootfs (via chroot) to customize a cloud image for PVE.
# Functionized so the pure-file edits can be unit-tested with bats (ROOT override);
# package installs and bootloader updates only run in production (ROOT=/).
#
# Steps that differ between distro families are delegated to
# scripts/family/<family>.sh, selected by the FAMILY environment variable that
# config/images.yaml provides. The shared steps below (timezone, motd, sysctl,
# cleanup, cloud-init) run for every family and are not duplicated per family.
set -Eeuo pipefail

ROOT="${ROOT:-/}"
FAMILY="${FAMILY:-debian}"
SOURCES_FILE="${SOURCES_FILE:?SOURCES_FILE is required}"
CLOUD_CFG="${CLOUD_CFG:?CLOUD_CFG is required}"
SOURCES_FORMAT="${SOURCES_FORMAT:?SOURCES_FORMAT is required}"
PACKAGES_FILE="${PACKAGES_FILE:-/tmp/cloud-image-packages.txt}"
SYSCTL_FILE="${SYSCTL_FILE:-/tmp/cloud-image-sysctl.conf}"

FAMILY_DIR="${FAMILY_DIR:-/tmp/family}"

root_path() {
  printf '%s%s\n' "$ROOT" "$1"
}

load_family() {
  local file="$FAMILY_DIR/$FAMILY.sh"
  [ -f "$file" ] || {
    echo "no family implementation for '$FAMILY' (looked for $file)" >&2
    return 1
  }
  # shellcheck disable=SC1090 # the path is data-driven by design
  . "$file"
}

# --- family hooks, called by the steps below -------------------------------

configure_apt_sources() {
  family_configure_sources
}

install_packages() {
  local packages
  packages="$(grep -Ev '^[[:space:]]*(#|$)' "$PACKAGES_FILE" | xargs)"
  [ -n "$packages" ] || { echo "no packages in $PACKAGES_FILE" >&2; return 1; }
  family_install_packages "$packages"
}

configure_cloud_init() {
  local cfg
  cfg="$(root_path "$CLOUD_CFG")"
  # cloud-init: do not regenerate apt sources at boot (file may be absent on Ubuntu)
  [ -f "$cfg" ] || return 0
  sed -i 's|generate_mirrorlists: true|generate_mirrorlists: false|g' "$cfg"
}

# PVE cloud-init applies cipassword to the *default* user, so root must be the
# default user (Ubuntu ships "ubuntu" with root locked, Rocky ships "rocky",
# CentOS 7 ships "centos") and unlocked, otherwise root password login never
# works. The family file names the entry to rename.
#
# Two different files are in play and they are not interchangeable:
#   $CLOUD_CFG (from config/images.yaml) - the per-distro vendor drop-in,
#     e.g. .../01_debian_cloud.cfg or .../99-fake_cloud.cfg, handled above.
#   /etc/cloud/cloud.cfg - the main config holding system_info.default_user;
#     it has no matrix entry because it is at the same path on every distro.
configure_cloud_cfg() {
  local cloud_cfg alias
  cloud_cfg="$(root_path /etc/cloud/cloud.cfg)"
  if [ ! -f "$cloud_cfg" ]; then
    echo "WARN: /etc/cloud/cloud.cfg missing, skipping cloud.cfg tweaks" >&2
    return 0
  fi
  sed -i 's|^disable_root:.*|disable_root: false|' "$cloud_cfg"
  grep -q '^disable_root:' "$cloud_cfg" || echo 'disable_root: false' >> "$cloud_cfg"
  sed -i 's|^ssh_pwauth:.*|ssh_pwauth: true|' "$cloud_cfg"
  grep -q '^ssh_pwauth:' "$cloud_cfg" || echo 'ssh_pwauth: true' >> "$cloud_cfg"

  # The family may name several candidates (rhel prints both rocky and centos);
  # rename whichever the image actually has, and unlock it. lock_passwd is only
  # touched when the rename happened, so an unrelated True elsewhere is not
  # rewritten by accident.
  while read -r alias; do
    [ -n "$alias" ] || continue
    if grep -q "^[[:space:]]*name: ${alias}$" "$cloud_cfg"; then
      echo "Renaming cloud-init default user '${alias}' to root"
      sed -i "s|^\([[:space:]]*\)name: ${alias}\$|\1name: root|" "$cloud_cfg"
      sed -i 's|^\([[:space:]]*\)lock_passwd: [Tt]rue$|\1lock_passwd: False|' "$cloud_cfg"
      break
    fi
  done < <(family_default_user_alias)

  # Keep the apt sources that PVE swaps in after download: without this Ubuntu
  # cloud-init regenerates sources.list(.d) on first boot and clobbers the
  # xtom HK mirror. Use the nested form: the older top-level
  # apt_preserve_sources_list is still accepted (cc_apt_configure converts it)
  # but logs a deprecation warning on every boot and is due for removal, which a
  # live guest confirmed:
  #   The following config key(s): ['apt_preserve_sources_list'] is deprecated
  #   in 22.1 and scheduled to be removed in 27.1.
  if [ "$FAMILY" = "debian" ]; then
    mkdir -p "$(root_path /etc/cloud/cloud.cfg.d)"
    printf 'apt:\n  preserve_sources_list: true\n' > "$(root_path /etc/cloud/cloud.cfg.d/99-pve-apt.cfg)"
  fi
}

configure_system() {
  # Timezone: Asia/Hong_Kong
  ln -sf /usr/share/zoneinfo/Asia/Hong_Kong "$(root_path /etc/localtime)"
  echo "Asia/Hong_Kong" > "$(root_path /etc/timezone)"

  # GRUB: disable os-prober (loopback detection breaks booting)
  local grub_cfg
  grub_cfg="$(root_path /etc/default/grub)"
  if [ ! -f "$grub_cfg" ]; then
    # Not fatal: the file is Debian's convention. RHEL family keeps its defaults
    # in /etc/default/grub too, so this only triggers on an unusual derivative,
    # and os-prober is not installed there in the first place.
    echo "WARN: $grub_cfg absent, skipping the os-prober tweak" >&2
  elif grep -q '^GRUB_DISABLE_OS_PROBER' "$grub_cfg"; then
    sed -i 's|^#\?GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=true|' "$grub_cfg"
  else
    printf '# disables OS prober to avoid loopback detection which breaks booting\nGRUB_DISABLE_OS_PROBER=true\n' >> "$grub_cfg"
  fi
  # Needs /proc mounted and the grub tools present, so it only makes sense in
  # production. In tests ROOT!=/ so skip.
  if [ "$ROOT" = "/" ]; then
    family_update_bootloader
  fi

  # Serial console on ttyS1 (default PVE serial terminal). Create the wants
  # directory first: RHEL-family images do not necessarily ship it, and without
  # it the symlink fails and the template never gets a serial console.
  mkdir -p "$(root_path /etc/systemd/system/getty.target.wants)"
  ln -sf /lib/systemd/system/serial-getty@.service \
    "$(root_path /etc/systemd/system/getty.target.wants/serial-getty@ttyS1.service)"

  family_configure_ntp

  configure_cloud_cfg
  # A family may add its own notices (CentOS 7 announces its end of life). Called
  # before the sshd work so the files land in the same /etc/motd.d the security
  # notice uses.
  family_eol_notice
  mkdir -p "$(root_path /etc/ssh/sshd_config.d)"
  printf 'PermitRootLogin yes\n' > "$(root_path /etc/ssh/sshd_config.d/99-pve-root-login.conf)"
  # A drop-in directory only takes effect if sshd_config includes it. RHEL-family
  # images (CentOS 7 in particular) ship no Include line, which would make the
  # PermitRootLogin above silently inert.
  if ! grep -q '^[[:space:]]*Include[[:space:]]*/etc/ssh/sshd_config.d' "$(root_path /etc/ssh/sshd_config)" 2>/dev/null; then
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' >> "$(root_path /etc/ssh/sshd_config)"
  fi

  # First-login warning for password-based root login. pam_motd reads
  # /etc/motd.d/ and that directory overrides /run/motd.d and /usr/lib/motd.d, so
  # the drop-in reaches SSH and console logins where motd.d is supported.
  mkdir -p "$(root_path /etc/motd.d)"
  # The unit is ssh on Debian and sshd on RHEL, so name it from the family hook
  # rather than hardcoding one; the operator pastes this command verbatim.
  cat > "$(root_path /etc/motd.d/99-pve-security)" <<MOTD
This image ships with password-based root SSH login enabled and its images are
published publicly. Keep this host on a controlled network (private subnet or a
security group restricted by source IP), and switch to key-based authentication
before exposing it. To disable password login:

    printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/99-pve-root-login.conf
    systemctl reload $(family_ssh_unit)
MOTD
  # CentOS 7's pam_motd predates motd.d support, so a notice living only in
  # /etc/motd.d would never be displayed there. Mirror the notices into
  # /etc/motd as well.
  #
  # Detection must look for the *directory* /etc/motd.d, not the substring
  # "motd.d": Debian's pam line is `motd=/run/motd.dynamic`, which contains that
  # substring and made this condition wrongly conclude motd.d was supported.
  if ! grep -qs '/etc/motd\.d\|motd_dir=' "$(root_path /etc/pam.d/sshd)" 2>/dev/null; then
    # A family may need to be told to consult pam_motd at all (the RHEL family does
  # not call it, so notices would otherwise never be shown).
  family_enable_motd

  # Every notice in motd.d, in the same lexicographic order pam_motd would use.
    # Create /etc/motd first: an image need not ship one, and appending to a
    # missing file aborts the build.
    touch "$(root_path /etc/motd)"
    for m in "$(root_path /etc/motd.d)"/*; do
      [ -f "$m" ] && cat "$m" >> "$(root_path /etc/motd)"
    done
  fi

  # BBR + kernel tuning. One template per family: CentOS 7's 3.10 kernel has no
  # BBR and no fq, so the RHEL file omits those keys rather than carrying
  # settings that silently do nothing.
  if [ "$FAMILY" = "debian" ]; then
    mkdir -p "$(root_path /etc/modules-load.d)"
    printf 'tcp_bbr\n' > "$(root_path /etc/modules-load.d/bbr.conf)"
  fi
  # Create the target directory rather than trusting the image to have it; the
  # serial-getty symlink below has the same requirement.
  mkdir -p "$(root_path /etc/sysctl.d)" "$(root_path /etc/systemd/system/getty.target.wants)"
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
  load_family
  configure_apt_sources
  configure_cloud_init
  install_packages
  configure_system
  # Applied last so it also covers anything the package install wrote into /usr.
  family_relabel
  cleanup_rootfs
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
