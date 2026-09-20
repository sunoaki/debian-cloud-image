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

  grub2_mkconfig_bios
}

# grub2-mkconfig decides which linux/initrd command to emit from the platform it
# detects, and inside our chroot that is the runner's view rather than the
# image's. Consequence, measured: a BIOS-only CentOS 7 image got a grub.cfg full
# of `linuxefi`/`initrdefi`, which the BIOS GRUB cannot execute, so the image
# failed to boot with "error: can't find command `linuxefi'". The stock upstream
# image correctly uses linux16/initrd16.
#
# The platform test behind that is `[ -d /sys/firmware/efi ]` in
# /etc/grub.d/10_linux, which inside the chroot asks about the *runner*. GitHub's
# runners are UEFI-booted, which is exactly why the BIOS-only image came out with
# EFI command names.
#
# So each generated config is pinned to the firmware that will read it, and the two
# are pinned independently: the BIOS config in /boot/grub2 (written by
# grub2_mkconfig_bios) and the ESP config (written by grub2_mkconfig_efi). The
# firmware a *boot test* should use is a different question and is not what decides
# this: the CentOS 7 entry of config/images.yaml ends up with both an ESP and its
# original MBR path, so FIRMWARE=efi there while the BIOS config still has to be
# written and pinned to BIOS command names.
#
# The rewrite covers both spellings because the two grub generations do not agree:
# CentOS 7 and Rocky 9 emit `linux16` for BIOS, while Rocky 10's newer grub emits
# plain `linux`. Only `linux16` has an EFI counterpart (`linuxefi`); `linux` is
# already valid on both platforms and must be left alone. Rewriting `linux` would
# turn it into `linuxefi`, which the BIOS GRUB then cannot find - the same failure
# in the other direction.

# Generate /boot/grub2/grub.cfg - the file the BIOS GRUB reads - and pin it to the
# BIOS command names.
grub2_mkconfig_bios() {
  local cfg
  if ! grub2-mkconfig -o "$(root_path /boot/grub2/grub.cfg)" 2>/dev/null; then
    echo "grub2-mkconfig failed" >&2
    return 1
  fi
  # Rewrite any EFI-only command names back to their BIOS equivalents. This is
  # deliberately a textual correction rather than another mkconfig run: the
  # command name is the only platform-specific part of these entries, and the
  # alternative (trusting detection inside the chroot) is what broke.
  cfg="$(root_path /boot/grub2/grub.cfg)"
  if grep -q '\blinuxefi\b\|\binitrdefi\b' "$cfg"; then
    sed -i 's/\blinuxefi\b/linux16/g; s/\binitrdefi\b/initrd16/g' "$cfg"
    echo "Rewrote EFI-only linuxefi/initrdefi to linux16/initrd16 in the BIOS grub.cfg"
  fi
  # Prove the result: a BIOS image must not carry EFI-only commands.
  if grep -q '\blinuxefi\b\|\binitrdefi\b' "$cfg"; then
    echo "grub.cfg still contains EFI-only commands on a BIOS image;" >&2
    echo "the image would fail to boot with \"can't find command \`linuxefi'\"." >&2
    return 1
  fi
}

# Generate the ESP's own grub.cfg and pin it to the EFI command names. The file
# path is the caller's, because both the vendor path and the removable-media path
# carry a copy of it (see family_esp_write_config).
grub2_mkconfig_efi() {
  local cfg="$1"
  if ! grub2-mkconfig -o "$cfg" 2>/dev/null; then
    echo "grub2-mkconfig for $cfg failed" >&2
    return 1
  fi
  # Only the BIOS spelling is converted here, in the opposite direction of
  # grub2_mkconfig_bios: plain `linux` (which newer grub emits and which EFI GRUB
  # also accepts) is left alone.
  if grep -q '\blinux16\b\|\binitrd16\b' "$cfg"; then
    sed -i 's/\blinux16\b/linuxefi/g; s/\binitrd16\b/initrdefi/g' "$cfg"
    echo "Rewrote linux16/initrd16 to linuxefi/initrdefi in the ESP grub.cfg"
  fi
  # Prove it: an EFI config that still asks for a 16-bit command would abort with
  # "error: can't find command `linux16'" before reaching a kernel.
  if grep -q '\blinux16\b\|\binitrd16\b' "$cfg"; then
    echo "The ESP grub.cfg still contains BIOS-only commands;" >&2
    echo "the image would fail to boot under UEFI with \"can't find command \`linux16'\"." >&2
    return 1
  fi
  # A config with no kernel entry at all would also never boot, and would pass the
  # two checks above. Rocky 9/10 emit no command name (their entries are a blscfg
  # call, which picks the right one at runtime), so this accepts either spelling.
  if ! grep -qE '^[[:space:]]*(linuxefi|linux|blscfg)\b' "$cfg"; then
    echo "The ESP grub.cfg has no kernel entry and no blscfg call" >&2
    return 1
  fi
}

# Write the ESP's grub.cfg and the copy the removable-media path reads.
#
# The file has real menu entries rather than a pointer at the BIOS one, because the
# two platforms cannot share entries here: CentOS 7's GRUB speaks linux16/initrd16
# for BIOS and linuxefi/initrdefi for EFI, and neither name exists in the other
# platform's GRUB. See grub2_mkconfig_efi for why Rocky can share and CentOS 7
# cannot.
#
# Written to the ESP so a kernel update of a running VM repoints it too, and
# generated from the same /etc/grub.d templates as the BIOS config, so the entries
# and the kernel command line stay identical between the two paths.
family_esp_write_config() {
  [ -n "${ESP_UUID:-}" ] || return 0
  [ -f /boot/efi/EFI/centos/grubx64.efi ] || return 0

  local cfg=/boot/efi/EFI/centos/grub.cfg
  grub2_mkconfig_efi "$cfg" || return 1

  # The removable-media path needs the same config: a firmware with no NVRAM boot
  # entry starts BOOTX64.EFI, and that GRUB has to find a menu.
  cp -a "$cfg" /boot/efi/EFI/BOOT/grub.cfg

  # Make the ESP a mount point for later kernel updates. Without this line the
  # running VM's /boot/efi is an empty directory and a kernel update would refresh
  # the kernel on the root filesystem while the firmware kept reading the old
  # payload off the ESP. Rocky's own images ship this line; CentOS 7's does not.
  if ! grep -q '[[:space:]]/boot/efi[[:space:]]' "$(root_path /etc/fstab)"; then
    printf 'UUID=%s /boot/efi vfat defaults,umask=0077,shortname=winnt 0 0\n' \
      "$ESP_UUID" >> "$(root_path /etc/fstab)"
    echo "Added /boot/efi to /etc/fstab"
  fi
}

# --- EFI system partition ---------------------------------------------------
#
# The hooks below configure UEFI boot for an image whose bootloader lives on an
# ESP that customize-image.sh created and mounted at /boot/efi. They are no-ops
# unless that ESP exists, so they are safe to call for every entry in the matrix.
#
# The shape of the result is the one Red Hat already ships on Rocky, which is the
# only tested layout in this family; the stock Rocky 9/10 images were read to
# confirm it rather than assumed:
#
#   ESP/EFI/BOOT/{BOOTX64.EFI,grubx64.efi,grub.cfg}   the removable-media path,
#                                                     which is what OVMF booted
#   ESP/EFI/centos/{shimx64.efi,grubx64.efi,grub.cfg} the vendor path
#
# Rocky's own generated EFI/centos/grub.cfg is a three-line pointer at the root
# filesystem's grub.cfg rather than a copy of it:
#
#   search --fs-uuid --set=root <root fs uuid>
#   set prefix=($root)/grub2
#   configfile ($root)/grub2/grub.cfg
#
# That works for Rocky because its /boot/grub2/grub.cfg holds no kernel command
# name to get wrong - it is a blscfg call, and blscfg picks the right command per
# platform at runtime. CentOS 7's grub.cfg does hold the command names, so the same
# pointer would make both firmwares share one spelling and only one of them would
# boot. Where the ESP is one the pipeline created (an efi_esp entry), the file is
# therefore a real config pinned to EFI, written by family_esp_write_config; on
# every other entry the pipeline writes nothing here and the distro's own file is
# left exactly as it shipped.
family_esp_configure() {
  [ -n "${ESP_UUID:-}" ] || return 0
  [ -d /boot/efi ] || return 0

  # EFI/BOOT is the fallback path a UEFI firmware uses when its NVRAM has no boot
  # entry - and a cloned VM has none, because the image is distributed without any
  # NVRAM. Measured on CentOS 7 under OVMF: "System BootOrder not found.
  # Initializing defaults." then a boot entry built for \EFI\centos\shimx64.efi.
  mkdir -p /boot/efi/EFI/centos /boot/efi/EFI/BOOT

  if rpm -q grub2-efi-x64 >/dev/null 2>&1; then
    echo "grub2-efi-x64 is already installed; reusing the image's own EFI binaries"
  else
    echo "Installing the EFI bootloader packages from the image's configured repositories"
    # shim-x64 is what makes Secure Boot possible at all and is what the firmware
    # prefers to start; mokutil and efivar-libs are its dependencies. Both packages
    # install their payloads straight into /boot/efi/EFI/centos, which is the ESP
    # mounted above, so nothing needs copying afterwards:
    #   shim-x64        shimx64.efi, shimx64-centos.efi, mmx64.efi, shim.efi
    #   grub2-efi-x64   grubx64.efi, fonts/unicode.pf2
    # (file lists read from the RPMs themselves, grub2-efi-x64 2.02-0.87.0.2 and
    # shim-x64 15-8). grub2-efi-x64-modules lands in /usr/lib/grub/x86_64-efi and is
    # what lets a running VM reinstall the EFI bootloader later.
    if ! yum -y install grub2-efi-x64 grub2-efi-x64-modules shim-x64; then
      echo "Could not install the EFI bootloader packages" >&2
      return 1
    fi
  fi

  [ -f /boot/efi/EFI/centos/grubx64.efi ] || {
    echo "grubx64.efi is still missing after installing the packages" >&2
    return 1
  }
  [ -f /boot/efi/EFI/centos/shimx64.efi ] || {
    echo "shimx64.efi is still missing after installing the packages" >&2
    return 1
  }

  # The removable-media path carries the same two stages under the names a
  # firmware looks for when it has been told nothing: BOOTX64.EFI is read as the
  # first stage whatever it is, so shim goes there and grubx64.efi sits beside it.
  cp -a /boot/efi/EFI/centos/shimx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  cp -a /boot/efi/EFI/centos/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi

  echo "ESP contents:"
  find /boot/efi -name '*.efi' | sort
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
