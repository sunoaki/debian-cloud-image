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

# Rocky and CentOS ship live repo files pointing at mirrorlist URLs, which is
# correct for them. Nothing to rewrite here; CentOS 7's dead mirrorlist is
# handled by its own vault drop-in (see config/ and the centos7 entry).
# Kept as an explicit no-op rather than removing the call so the hook contract
# stays identical across families.
family_configure_sources() {
  return 0
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

  grub2-mkconfig -o /boot/grub2/grub.cfg
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
# (sed -i, printf >, install) carry no security.selinux xattr. An unlabeled file
# is denied by type enforcement.
#
# Relabelling at build time is NOT possible on a GitHub-hosted runner, and this
# was measured rather than assumed: writing a security.selinux xattr fails with
# EPERM even as uid 0 in a privileged container with every capability
# (CapEff=000001ffffffffff), while user.* on the same file succeeds. The cause is
# the kernel/LSM: the runner's kernel has SELinux compiled in but not enabled, so
# no handler claims the security.selinux name and setfiles would silently write
# nothing -- reporting success over an image that ships unlabeled.
#
# So the relabel is deferred to first boot, which is also Red Hat's documented
# mechanism: "Use the `fixfiles -F onboot` command as root to create the
# /.autorelabel file containing the -F option to ensure that files are relabeled
# upon next reboot." (RHEL 9, Changing SELinux states and modes.)
#
# Costs, stated plainly because they are real: the first boot of a derived VM
# relabels before the login prompt appears, which takes minutes, so the advisory
# boot test for RHEL entries must not expect a prompt inside its normal budget.
family_relabel() {
  local ctx
  ctx="$(root_path /etc/selinux/targeted/contexts/files/file_contexts)"
  [ -f "$ctx" ] || {
    echo "WARN: no SELinux file_contexts in the image; skipping relabel" >&2
    return 0
  }
  printf -- '-F\n' > "$(root_path /.autorelabel)"
  echo "SELinux relabel deferred to first boot via /.autorelabel (-F)"
  echo "NOTE: first boot relabels before the login prompt and takes minutes"
}

# PVE's cloud-init applies cipassword to the default user, which differs even
# within this family: "rocky" on Rocky, "centos" on CentOS 7. Print every
# candidate; customize-rootfs.sh renames whichever one the image actually has, so
# no per-entry matrix field is needed and a new RHEL derivative only has to add
# its name here.
family_default_user_alias() {
  printf 'rocky\ncentos\n'
}
