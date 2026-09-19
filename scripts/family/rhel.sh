#!/usr/bin/env bash
# family/rhel.sh
# RHEL-family (Rocky Linux, CentOS) implementations of the hooks that differ
# between distro families. Selected by config/images.yaml's `family` field and
# sourced by customize-rootfs.sh; the shared steps (timezone, motd, sysctl,
# cleanup, cloud-init) live in customize-rootfs.sh and are not repeated here.
#
# Names verified against real images: Rocky 9.8/10.2 and CentOS 7.9.2009. The
# unit names and tool names below are not the Debian ones — `sshd` not `ssh`,
# `grub2-mkconfig` not `update-grub`, `chronyd` not `timesyncd`.

family_install_packages() {
  local packages="$1"

  # CentOS 7 has no dnf4: its `dnf` is a thin Python shim over yum and `dnf
  # makecache` is not universally present, so use yum there. Rocky ships dnf4
  # with `yum` as a symlink, so either name works and dnf is the supported one.
  local pm=dnf
  if [ -f "$(root_path /etc/centos-release)" ]; then
    pm=yum
  fi

  "$pm" -y makecache || true
  "$pm" -y update
  # shellcheck disable=SC2086 # packages list is intended to word-split
  "$pm" -y install $packages
  # No --purge equivalent: dnf removes config files with the package, and
  # clean_requirements_on_remove=True in dnf.conf already prunes orphans.
  "$pm" -y autoremove
}

# Rocky ships live repo files pointing at mirrorlist URLs, which is correct and
# left alone. CentOS 7 is different: mirrorlist.centos.org is gone (measured
# NXDOMAIN, and the guest's yum fails with "Cannot find a valid baseurl"), so the
# stock repos are dead on arrival and `yum` cannot install anything until they
# point at the vault. The image's own CentOS-Vault.repo only defines sections up
# to C7.8.2003, so the 7.9.2009 paths are written fresh.
#
# This is why the redirection belongs here rather than at delivery time: without
# it the build itself cannot install packages, and the shipped template would
# have a yum that fails for the operator too.
family_configure_sources() {
  local repo="$ROOT/etc/yum.repos.d/CentOS-Base.repo" vault="$ROOT/etc/yum.repos.d/99-pve-vault.repo"
  # Only CentOS 7 needs this; identify it by the repo the matrix names.
  case "${SOURCES_FILE:-}" in
  */CentOS-Base.repo) ;;
  *) return 0 ;;
  esac

  # Disable the dead mirrorlist-backed repos, then add the vaulted equivalents.
  # Rewriting in place is what the earlier verification exercised, so the same
  # shape is used here.
  if [ -f "$repo" ]; then
    mkdir -p "$ROOT/etc/yum.repos.d"
    cat > "$vault" <<'VAULT'
# PVE cloud-image: CentOS 7 reached end of life on 2024-06-30 and its content
# moved off the mirrors to vault.centos.org, where it is frozen permanently.
# mirrorlist.centos.org no longer resolves, so the stock repositories cannot work.
# No further security updates will ever appear for this release.
[base]
name=CentOS-7 - Base (vaulted)
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7 - Updates (vaulted)
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7 - Extras (vaulted)
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
VAULT
    # Turn the original file's repositories off rather than deleting it, so the
    # image still shows what upstream shipped.
    sed -i 's/^enabled=1/enabled=0/' "$repo"
    sed -i 's/^mirrorlist=/# mirrorlist=/' "$repo"
    echo "Rewrote CentOS 7 repositories to the vault at vault.centos.org/7.9.2009"
  else
    echo "WARN: $repo not found; CentOS 7 package install will fail" >&2
  fi
}

# RHEL family uses grub2-mkconfig directly. The Debian wrapper `update-grub` does
# not exist on these images (verified absent on Rocky 9.8 and 10.2).
#
# /boot may be a separate partition (XBOOTLDR), in which case it is mounted at
# $MNT/boot by customize-image.sh and this path is correct.
#
# Why this rewrites the BLS entries instead of trusting them:
# Rocky sets GRUB_ENABLE_BLSCFG=true, so the kernel cmdline lives in
# /boot/loader/entries/*.conf and GRUB boots the newest one. kernel-install, run
# by dnf inside our chroot, generated entries containing
#   root=PARTUUID=<value the build kernel saw>
# which is NOT the finished image's PARTUUID. The shipped image then died with
#   /dev/disk/by-partuuid/580b80dc-... does not exist
#   Entering emergency mode ... dracut:/#
# while the stock upstream image booted fine -- the image was broken by our own
# build. Debian/Ubuntu never hit this because they have no BLS entries and
# update-grub derives root=UUID= from /etc/fstab.
#
# The fix is to make every entry reference the filesystem UUID that /etc/fstab
# already uses, which is stable and correct inside the image. Rewriting the text
# is deliberate: asking kernel-install to do it again would re-read the same
# build-time view that produced the wrong value.
family_update_bootloader() {
  local entries entry root_uuid fixed=0

  # The root entry in /etc/fstab already uses the correct, stable spelling
  # (UUID=<fs uuid>); take the value from there rather than probing a device,
  # because inside the chroot the device name is not the one the image will use.
  root_uuid="$(awk '$2 == "/" { print $1; exit }' "$(root_path /etc/fstab)" 2>/dev/null |
    sed -n 's/^UUID=//p')"

  entries="$(compgen -G "$(root_path /boot/loader/entries)/"'*.conf' || true)"
  if [ -z "${root_uuid:-}" ]; then
    echo "WARN: no UUID= root entry in /etc/fstab; leaving BLS entries alone" >&2
  elif [ -z "$entries" ]; then
    echo "No BLS entries to check (GRUB_ENABLE_BLSCFG not in use)"
  else
    for entry in $entries; do
      # Only a PARTUUID reference is wrong: it is a value the build kernel saw,
      # not one the finished image has. A UUID reference is already correct.
      if grep -q 'root=PARTUUID=' "$entry"; then
        sed -i "s|root=PARTUUID=[0-9a-fA-F-]*|root=UUID=${root_uuid}|g" "$entry"
        fixed=$((fixed + 1))
      fi
    done
    echo "Rewrote root=PARTUUID= to root=UUID=${root_uuid} in $fixed BLS entr(ies)"
  fi

  # Fail loudly if any entry still names a root this image does not have. This is
  # the check whose absence let a non-booting Rocky image ship: the old
  # assertions counted kernels and initrds, which stayed correct while every
  # entry pointed at a partition that did not exist.
  local bad=0
  for entry in $entries; do
    local ref
    ref="$(sed -n 's/.*root=\([^ ]*\).*/\1/p' "$entry" | head -1)"
    case "$ref" in
    UUID=*) ok=1 ;;
    PARTUUID=*) ok=0 ;;
    /dev/*) ok=1 ;;
    *) ok=1 ;;
    esac
    if [ "${ok:-1}" -eq 0 ]; then
      echo "BLS entry $(basename "$entry") still uses $ref" >&2
      bad=$((bad + 1))
    fi
  done
  if [ "$bad" -gt 0 ]; then
    echo "Refusing to continue: $bad BLS entry(ies) reference a PARTUUID, which is" >&2
    echo "a build-time value the finished image does not have. It would boot into" >&2
    echo "a dracut emergency shell instead of the system." >&2
    return 1
  fi

  grub2_mkconfig_for_firmware
}

# grub2-mkconfig decides which linux/initrd command to emit from the platform it
# detects, and inside our chroot that is the runner's view rather than the
# image's. Consequence, measured: a BIOS-only CentOS 7 image got a grub.cfg full
# of `linuxefi`/`initrdefi`, which the BIOS GRUB cannot execute, so the image
# failed to boot with "error: can't find command `linuxefi'". The stock upstream
# image correctly uses linux16/initrd16.
#
# The firmware is already known from the partition table (no ESP => BIOS), so pin
# the generation to it instead of letting the build host decide. For a BIOS image
# that means asking for the i386-pc platform explicitly; for UEFI the default is
# already right.
grub2_mkconfig_for_firmware() {
  if [ "${FIRMWARE:-}" = "bios" ]; then
    if ! grub2-mkconfig -o "$(root_path /boot/grub2/grub.cfg)" 2>/dev/null; then
      echo "grub2-mkconfig failed" >&2
      return 1
    fi
    # Rewrite any EFI-only command names back to their BIOS equivalents. This is
    # deliberately a textual correction rather than another mkconfig run: the
    # command name is the only platform-specific part of these entries, and the
    # alternative (trusting detection inside the chroot) is what broke.
    local cfg fixed=0
    cfg="$(root_path /boot/grub2/grub.cfg)"
    if grep -q '\blinuxefi\b\|\binitrdefi\b' "$cfg"; then
      sed -i 's/\blinuxefi\b/linux16/g; s/\binitrdefi\b/initrd16/g' "$cfg"
      fixed=1
    fi
    if [ "$fixed" -eq 1 ]; then
      echo "Rewrote EFI-only linuxefi/initrdefi to linux16/initrd16 for a BIOS image"
    fi
    # Prove the result: a BIOS image must not carry EFI-only commands.
    if grep -q '\blinuxefi\b\|\binitrdefi\b' "$cfg"; then
      echo "grub.cfg still contains EFI-only commands on a BIOS image;" >&2
      echo "the image would fail to boot with \"can't find command \`linuxefi'\"." >&2
      return 1
    fi
  else
    grub2-mkconfig -o "$(root_path /boot/grub2/grub.cfg)"
  fi
}

# The unit is sshd, not ssh. The motd text tells the operator to reload it.
family_ssh_unit() {
  printf 'sshd\n'
}

# timesyncd does not exist on RHEL family; chrony does, and it is enabled by
# default. The image already points at public pools, so the only change worth
# making is to the same NTP sources the Debian family uses, for consistency.
family_configure_ntp() {
  local cfg
  cfg="$(root_path /etc/chrony.conf)"
  [ -f "$cfg" ] || return 0
  if ! grep -q '^pool time.apple.com' "$cfg"; then
    printf '\n# PVE cloud-image: use the same NTP sources as the Debian-family images\npool time.apple.com iburst\n' >> "$cfg"
  fi
}

# RHEL family defaults SELinux to enforcing, and files written from this chroot
# (sed -i, printf >, install) carry no security.selinux xattr. That is not
# cosmetic: systemd 257 in Rocky 10 refuses to start at all when it cannot set
# contexts and raise RLIMIT_NOFILE against unlabeled state:
#   systemd[1]: Failed to allocate manager object: Permission denied
# which it reported as a hang with no login prompt. Rocky 9's older systemd
# tolerated the same unlabeled state, which is why this only appeared when 10
# was added.
#
# Relabelling at build time is not possible on a GitHub-hosted runner, measured
# rather than assumed: writing a security.selinux xattr returns EPERM even as
# uid 0 in a privileged container with every capability, while user.* on the same
# file succeeds, because the runner kernel has SELinux compiled in but not
# enabled and nothing claims that xattr name. setfiles would silently write
# nothing while reporting success.
#
# So labels are fixed on first boot instead, which is Red Hat's documented
# mechanism ("Use the `fixfiles -F onboot` command as root to create the
# /.autorelabel file containing the -F option to ensure that files are relabeled
# upon next reboot", RHEL 9 Changing SELinux states and modes). For that first
# boot to succeed while still unlabeled, SELinux must be permissive during it;
# the relabel then runs, and enforcing is restored. Without this the image hangs
# before any login prompt, which is exactly what happened.
family_relabel() {
  local ctx selinux_cfg
  ctx="$(root_path /etc/selinux/targeted/contexts/files/file_contexts)"
  selinux_cfg="$(root_path /etc/selinux/config)"
  [ -f "$ctx" ] || {
    echo "WARN: no SELinux file_contexts in the image; skipping relabel" >&2
    return 0
  }

  printf -- '-F\n' > "$(root_path /.autorelabel)"

  # Permissive for the first boot only. /usr/libexec/selinux-autorelabel (run by
  # selinux-autorelabel.service) rewrites /etc/selinux/config back to enforcing
  # after relabelling, so the delivered VM ends up enforcing with correct labels.
  if [ -f "$selinux_cfg" ]; then
    if grep -q '^SELINUX=enforcing' "$selinux_cfg"; then
      sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "$selinux_cfg"
      # Record the intent, and make the restore independent of whether
      # selinux-autorelabel's own restore runs (it can be skipped if the relabel
      # is interrupted). A oneshot unit is the least surprising place for it.
      mkdir -p "$(root_path /etc/systemd/system)"
      cat > "$(root_path /etc/systemd/system/99-pve-restore-selinux.service)" <<'UNIT'
[Unit]
Description=Restore enforcing SELinux after the first-boot relabel
After=selinux-autorelabel.service
ConditionPathExists=/etc/selinux/config

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'sed -i "s/^SELINUX=permissive/SELINUX=enforcing/" /etc/selinux/config'
ExecStart=/usr/bin/rm -f /.autorelabel

[Install]
WantedBy=multi-user.target
UNIT
      mkdir -p "$(root_path /etc/systemd/system/multi-user.target.wants)"
      ln -sf ../99-pve-restore-selinux.service \
        "$(root_path /etc/systemd/system/multi-user.target.wants/99-pve-restore-selinux.service)"
      echo "SELinux: permissive for the first boot, relabelled via /.autorelabel, then enforcing"
    else
      echo "SELinux: image is not enforcing; only /.autorelabel was written"
    fi
  else
    echo "WARN: no /etc/selinux/config; not touching SELinux state" >&2
  fi
}

# PVE's cloud-init applies cipassword to the default user, which differs even
# within this family: "rocky" on Rocky, "centos" on CentOS 7. Print every
# candidate; customize-rootfs.sh renames whichever one the image actually has, so
# no per-entry matrix field is needed and a new RHEL derivative only has to add
# its name here.
family_default_user_alias() {
  printf 'rocky\ncentos\n'
}

# CentOS 7 is past end of life, so an operator who inherits a VM built from this
# image should be told plainly rather than discovering it from a failed yum.
# Printed on first login via the same mechanism as the security notice, and also
# written into the image's motd so it survives for images whose pam_motd predates
# motd.d (which is exactly CentOS 7's case).
family_eol_notice() {
  case "${SOURCES_FILE:-}" in
  */CentOS-Base.repo) ;;
  *) return 0 ;;
  esac
  mkdir -p "$(root_path /etc/motd.d)"
  cat > "$(root_path /etc/motd.d/98-pve-eol)" <<'EOL'
WARNING: CentOS 7 reached end of life on 2024-06-30.

This image was built from the frozen vault at vault.centos.org/7.9.2009 and will
never receive another security update. Do not expose it to an untrusted network.
Plan a migration to a supported release.
EOL
  echo "Added a CentOS 7 end-of-life notice to /etc/motd.d/98-pve-eol"
}

# RHEL-family images do not call pam_motd at all: /etc/pam.d/sshd and
# /etc/pam.d/login have no motd line, so a notice written into /etc/motd or
# /etc/motd.d is never displayed over SSH or on the console. Debian and Ubuntu do
# call it, which is why the shared motd work is enough there.
#
# Adding the pam line is what makes the notices actually reach an operator.
# RHEL 7+ ships pam_motd with motd= support (pam-1.1.8 on CentOS 7), and it is
# already in the image, so this needs no new package. Ordered after the existing
# session rules and with a leading '-' so a missing file is not an error.
#
# This matters most for CentOS 7, whose whole point of the notice is to tell an
# operator the release is unsupported before they expose it.
family_enable_motd() {
  local f added=0
  for f in "$(root_path /etc/pam.d/sshd)" "$(root_path /etc/pam.d/login)"; do
    [ -f "$f" ] || continue
    grep -q 'pam_motd' "$f" && continue
    printf 'session    optional     pam_motd.so
' >> "$f"
    added=$((added + 1))
  done
  if [ "$added" -gt 0 ]; then
    echo "Enabled pam_motd in $added pam config(s) so login notices are shown"
  fi
}
