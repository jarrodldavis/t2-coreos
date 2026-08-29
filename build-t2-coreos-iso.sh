#!/usr/bin/env bash
#
# build-t2-coreos-iso.sh -- produce a self-installing Fedora CoreOS ISO
# for a T2 MacBook Pro, with LUKS root encryption and t2linux enablement.
#
# Requires: bash, curl, and either podman (default) or native
# butane + coreos-installer binaries (NATIVE=1).
#
# Usage:
#   SSH_KEY=~/.ssh/id_ed25519.pub ./build-t2-coreos-iso.sh
#
set -euo pipefail

# --------------------------------------------------------------------
# Parameters
# --------------------------------------------------------------------
: "${SSH_KEY:?set SSH_KEY to your public key file or literal key}"
: "${DISK:=/dev/nvme0n1}"          # install target
: "${STREAM:=stable}"              # stable | testing | next
: "${FCOS_HOSTNAME:=t2mac}"
: "${OUTDIR:=./out}"

# LUKS mode:
#   enroll (default) -- Ignition formats root with a throwaway random key;
#                       you set the real passphrase once, on first boot.
#                       No long-term secret ever lands in the ISO or /boot.
#   embed            -- LUKS_PASSPHRASE is baked into the ISO. Fully
#                       unattended, but the ISO and /boot/ignition/config.ign
#                       both contain your passphrase in cleartext.
: "${LUKS_MODE:=enroll}"
: "${LUKS_PASSPHRASE:=}"

# Optional extra Clevis/Tang binding. An IP or a *.local mDNS name both
# work; a .local URL automatically pulls an mDNS resolver into the
# initramfs (see TANG_MDNS below).
: "${TANG_URL:=}"
: "${TANG_THUMBPRINT:=}"

# Kernel args for the *live installer* environment, if it needs help booting.
: "${LIVE_KARGS:=}"

COPR_OWNER=sharpenedblade
COPR_PROJECT=t2linux
COPR_BASE="https://download.copr.fedorainfracloud.org/results/${COPR_OWNER}/${COPR_PROJECT}"

BUTANE_IMG=quay.io/coreos/butane:release
INSTALLER_IMG=quay.io/coreos/coreos-installer:release

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$LUKS_MODE" == "enroll" || "$LUKS_MODE" == "embed" ]] \
  || die "LUKS_MODE must be 'enroll' or 'embed'"
[[ "$LUKS_MODE" == "embed" && -z "$LUKS_PASSPHRASE" ]] \
  && die "LUKS_MODE=embed requires LUKS_PASSPHRASE"
[[ -n "$TANG_URL" && -z "$TANG_THUMBPRINT" ]] \
  && die "TANG_URL requires TANG_THUMBPRINT (get it: clevis-encrypt-tang or tang-show-keys)"

# A *.local Tang URL needs an mDNS resolver in the initramfs. We get one by
# pulling systemd-resolved into the initramfs: its stub listener on
# 127.0.0.53 speaks MulticastDNS, and it treats .local as an mDNS-only
# domain. Auto-enable when the URL is mDNS; allow forcing it on.
: "${TANG_MDNS:=auto}"
if [[ "$TANG_MDNS" == "auto" ]]; then
  if [[ "$TANG_URL" == *.local* || "$TANG_URL" == *.local:* ]]; then TANG_MDNS=1; else TANG_MDNS=0; fi
fi
[[ "$TANG_MDNS" == "1" && -z "$TANG_URL" ]] && die "TANG_MDNS=1 without TANG_URL"

mkdir -p "$OUTDIR"
WORK="$(mktemp -d)"
FILESDIR="$WORK/files"
mkdir -p "$FILESDIR"
chmod 700 "$WORK" "$FILESDIR"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------
# Gather inputs
# --------------------------------------------------------------------
if [[ -f "$SSH_KEY" ]]; then SSH_KEY_VALUE="$(< "$SSH_KEY")"; else SSH_KEY_VALUE="$SSH_KEY"; fi
SSH_KEY_VALUE="${SSH_KEY_VALUE%%$'\n'*}"
[[ "$SSH_KEY_VALUE" == ssh-* || "$SSH_KEY_VALUE" == ecdsa-* ]] \
  || die "SSH_KEY does not look like a public key"

# The LUKS key is passed as a *file* and referenced with Butane's `local:`
# directive, so it is embedded byte-for-byte with no trailing newline and
# no shell/YAML quoting hazards. A LUKS keyslot does not distinguish a
# "key file" from a "passphrase" -- both are just key material -- so a
# volume formatted with these bytes unlocks when you type them at the prompt.
if [[ "$LUKS_MODE" == "embed" ]]; then
  printf '%s' "$LUKS_PASSPHRASE" > "$FILESDIR/luks.key"
else
  openssl rand -base64 48 | tr -d '\n' > "$FILESDIR/luks.key"
fi
chmod 600 "$FILESDIR/luks.key"

if [[ -n "${COPR_GPG_KEY_FILE:-}" ]]; then
  log "Using COPR signing key from $COPR_GPG_KEY_FILE"
  cp "$COPR_GPG_KEY_FILE" "$FILESDIR/copr.gpg"
else
  log "Fetching t2linux COPR signing key"
  curl -fsSL "$COPR_BASE/pubkey.gpg" -o "$FILESDIR/copr.gpg" \
    || die "could not fetch COPR signing key. Download it manually from
       $COPR_BASE/pubkey.gpg
     and re-run with COPR_GPG_KEY_FILE=/path/to/pubkey.gpg"
fi
grep -q 'BEGIN PGP PUBLIC KEY' "$FILESDIR/copr.gpg" \
  || die "COPR key file does not look like an ASCII-armored PGP key"

# --------------------------------------------------------------------
# Optional Tang binding
# --------------------------------------------------------------------
CLEVIS_BLOCK=""
if [[ -n "$TANG_URL" ]]; then
  CLEVIS_BLOCK=$(cat <<EOF

      clevis:
        tang:
          - url: $TANG_URL
            thumbprint: $TANG_THUMBPRINT
EOF
)
fi

# --------------------------------------------------------------------
# mDNS in the initramfs
#
# systemd-resolved implements MulticastDNS and refuses to leak .local to
# unicast DNS. Two paths reach it, and we wire up both so we don't depend
# on which one NetworkManager leaves in place:
#   1. nsswitch "resolve" -> nss-resolve talks to resolved directly
#   2. resolv.conf -> 127.0.0.53 stub, which also answers mDNS
# --------------------------------------------------------------------
T2_PKGS="t2fanrd rust-tiny-dfr t2linux-audio"
MDNS_FILES=""
MDNS_DRACUT_ARGS=""
if [[ "$TANG_MDNS" == "1" ]]; then
  T2_PKGS="$T2_PKGS systemd-resolved"
  MDNS_DRACUT_ARGS='--arg=-I --arg=/etc/nsswitch.conf'
  MDNS_FILES=$(cat <<'EOF'

    - path: /etc/dracut.conf.d/40-mdns.conf
      mode: 0644
      contents:
        inline: |
          add_dracutmodules+=" systemd-resolved "
          install_optional_items+=" /usr/lib64/libnss_resolve.so.2 "

    - path: /etc/systemd/resolved.conf.d/10-mdns.conf
      mode: 0644
      contents:
        inline: |
          [Resolve]
          MulticastDNS=yes
          LLMNR=no

    # NetworkManager must not disable mDNS on the link, and must hand
    # resolution to resolved rather than writing its own resolv.conf.
    - path: /etc/NetworkManager/conf.d/10-mdns.conf
      mode: 0644
      contents:
        inline: |
          [connection]
          connection.mdns=2
          [main]
          dns=systemd-resolved

    # Included into the initramfs via dracut -I so nss-resolve is
    # consulted before plain dns for .local lookups.
    - path: /etc/nsswitch.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          passwd:     files systemd
          group:      files systemd
          shadow:     files
          hosts:      files resolve [!UNAVAIL=return] myhostname dns
          services:   files
          netgroup:   files
          automount:  files
          aliases:    files
          ethers:     files
          gshadow:    files
          networks:   files dns
          protocols:  files
          publickey:  files
          rpc:        files
EOF
)
fi

# --------------------------------------------------------------------
# Render the Butane config
#
# NOTE: \$releasever and \$basearch are escaped -- they must survive into
# the .repo file so the COPR follows FCOS across Fedora rebases on its own.
# --------------------------------------------------------------------
BU="$OUTDIR/t2-fcos.bu"
cat > "$BU" <<EOF
variant: fcos
version: 1.7.0

passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - $SSH_KEY_VALUE

# ---------------------------------------------------------------------
# Encrypted root.
#
# We do NOT use the boot_device.luks sugar: it only emits Clevis pins, and
# with no pin it silently produces an empty config. Writing storage.luks
# by hand lets us format the volume with plain key material.
#
# On later boots, coreos-boot-edit injects "rd.luks.name=<uuid>=root" into
# the BLS entry, so unlocking runs through stock systemd-cryptsetup, which
# prompts on the console. Clevis, when bound, just answers that prompt
# automatically -- so Tang and passphrase coexist with no extra plumbing.
# ---------------------------------------------------------------------
storage:
  disks:
    - device: /dev/disk/by-id/coreos-boot-disk
      wipe_table: false
      partitions:
        - label: root
          number: 4
          size_mib: 0
          resize: true

  luks:
    - name: root
      label: luks-root
      device: /dev/disk/by-partlabel/root
      wipe_volume: true
      discard: true
      key_file:
        local: luks.key$CLEVIS_BLOCK

  filesystems:
    - device: /dev/mapper/root
      format: xfs
      wipe_filesystem: true
      label: root

  directories:
    - path: /var/lib/firmware/brcm
      mode: 0755

  files:
    - path: /etc/hostname
      mode: 0644
      contents:
        inline: $FCOS_HOSTNAME

    - path: /etc/yum.repos.d/t2linux.repo
      mode: 0644
      contents:
        inline: |
          [copr:copr.fedorainfracloud.org:$COPR_OWNER:$COPR_PROJECT]
          name=Copr repo for $COPR_PROJECT owned by $COPR_OWNER
          baseurl=$COPR_BASE/fedora-\$releasever-\$basearch/
          type=rpm-md
          skip_if_unavailable=False
          gpgcheck=1
          gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-t2linux
          repo_gpgcheck=0
          enabled=1
          priority=80

    - path: /etc/pki/rpm-gpg/RPM-GPG-KEY-t2linux
      mode: 0644
      contents:
        local: copr.gpg

    # apple-bce in the initramfs -> internal keyboard works at the LUKS prompt
    - path: /etc/dracut.conf.d/t2linux-modules.conf
      mode: 0644
      contents:
        inline: |
          force_drivers+=" apple-bce "

$MDNS_FILES
    - path: /etc/modprobe.d/t2-eth-blocklist.conf
      mode: 0644
      contents:
        inline: |
          blacklist cdc_ncm
          blacklist cdc_mbim

    - path: /etc/systemd/logind.conf.d/10-t2-no-suspend.conf
      mode: 0644
      contents:
        inline: |
          [Login]
          HandlePowerKey=ignore
          HandlePowerKeyLongPress=poweroff
          HandleSuspendKey=ignore
          HandleHibernateKey=ignore
          HandleLidSwitch=ignore
          HandleLidSwitchExternalPower=ignore
          HandleLidSwitchDocked=ignore

    - path: /etc/zincati/config.d/55-updates-strategy.toml
      mode: 0644
      contents:
        inline: |
          [updates]
          strategy = "periodic"
          [[updates.periodic.window]]
          days = [ "Sat" ]
          start_time = "03:00"
          length_minutes = 120

    # -----------------------------------------------------------------
    # T2 enablement. Runs once, on first boot.
    #
    # The kernel override is deliberately NOT --freeze: rpm-ostree
    # re-resolves it from the COPR on every subsequent upgrade, so FCOS
    # and t2linux both keep flowing in with no image to maintain. If the
    # COPR has no build for a new Fedora release, the whole transaction
    # fails and no deployment is created -- it fails closed rather than
    # staging an unbootable kernel.
    # -----------------------------------------------------------------
    - path: /usr/local/bin/t2-enablement
      mode: 0755
      contents:
        inline: |
          #!/bin/bash
          set -euo pipefail
          systemctl stop zincati.service || true

          rpm-ostree initramfs --enable $MDNS_DRACUT_ARGS
          rpm-ostree override replace \\
            --experimental \\
            --from repo=copr:copr.fedorainfracloud.org:$COPR_OWNER:$COPR_PROJECT \\
            kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra
          rpm-ostree install -y $T2_PKGS

          touch /var/lib/t2-enablement.stamp
          systemctl reboot

    # -----------------------------------------------------------------
    # LUKS passphrase enrollment (LUKS_MODE=enroll only).
    #
    # Runs on the boot *after* t2 enablement, so apple-bce is loaded and
    # the built-in keyboard works. Adds your passphrase, then removes the
    # throwaway install key -- which makes the copy of that key sitting in
    # /boot/ignition/config.ign worthless, so /boot never has to be touched.
    # -----------------------------------------------------------------
    - path: /usr/local/bin/luks-enroll
      mode: 0755
      contents:
        inline: |
          #!/bin/bash
          set -euo pipefail
          DEV=/dev/disk/by-partlabel/root
          INSTALL_KEY=/etc/luks-install.key
          [[ -f \$INSTALL_KEY ]] || { echo "already enrolled"; exit 0; }

          for i in 1 2 3; do
            P1=\$(systemd-ask-password --no-tty "Set a LUKS passphrase for this disk:") || exit 1
            P2=\$(systemd-ask-password --no-tty "Confirm passphrase:") || exit 1
            [[ "\$P1" == "\$P2" && -n "\$P1" ]] && break
            echo "Passphrases did not match, try again." >&2
            P1=""
          done
          [[ -n "\$P1" ]] || { echo "giving up" >&2; exit 1; }

          printf '%s\\n' "\$P1" | cryptsetup luksAddKey --batch-mode \\
            --key-file "\$INSTALL_KEY" "\$DEV" -
          cryptsetup luksRemoveKey --batch-mode --key-file "\$INSTALL_KEY" "\$DEV"
          shred -u "\$INSTALL_KEY"
          echo "Passphrase enrolled; install key removed."
EOF

# In enroll mode, drop the install key onto the (encrypted) root so the
# enrollment service can authenticate the keyslot change.
if [[ "$LUKS_MODE" == "enroll" ]]; then
cat >> "$BU" <<EOF

    - path: /etc/luks-install.key
      mode: 0600
      contents:
        local: luks.key
EOF
fi

cat >> "$BU" <<EOF

kernel_arguments:
  should_exist:
    - intel_iommu=on
    - iommu=pt
    - mem_sleep_default=s2idle
    - firmware_class.path=/var/lib/firmware

systemd:
  units:
    - name: t2-enablement.service
      enabled: true
      contents: |
        [Unit]
        Description=Apply t2linux kernel and packages on first boot
        Wants=network-online.target
        After=network-online.target luks-enroll.service
        ConditionPathExists=!/var/lib/t2-enablement.stamp
        # Never reboot into a disk whose only key is the throwaway
        # install key -- enrollment must have removed it first.
        ConditionPathExists=!/etc/luks-install.key

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/bin/t2-enablement

        [Install]
        WantedBy=multi-user.target
EOF

if [[ "$LUKS_MODE" == "enroll" ]]; then
cat >> "$BU" <<EOF

    - name: luks-enroll.service
      enabled: true
      contents: |
        [Unit]
        Description=Enroll a LUKS passphrase and drop the install key
        DefaultDependencies=no
        After=basic.target
        Before=t2-enablement.service
        ConditionPathExists=/etc/luks-install.key

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/local/bin/luks-enroll
        StandardOutput=journal+console
        StandardError=journal+console

        [Install]
        WantedBy=multi-user.target
EOF
fi

# --------------------------------------------------------------------
# Transpile + build the ISO
# --------------------------------------------------------------------
cp "$BU" "$WORK/config.bu"

ABS_OUT="$(cd "$OUTDIR" && pwd)"

if [[ "${NATIVE:-0}" == "1" ]]; then
  command -v butane >/dev/null || die "butane not found (unset NATIVE to use podman)"
  command -v coreos-installer >/dev/null || die "coreos-installer not found"
  W="$WORK"; O="$ABS_OUT"
  run_butane()    { butane "$@"; }
  run_installer() { coreos-installer "$@"; }
else
  command -v podman >/dev/null || die "podman not found (or set NATIVE=1)"
  W=/w; O=/out
  run_butane() {
    podman run --rm -i --security-opt label=disable \
      -v "$WORK:/w:z" -w /w "$BUTANE_IMG" "$@"
  }
  run_installer() {
    podman run --rm -i --security-opt label=disable --pull=always \
      -v "$WORK:/w:z" -v "$ABS_OUT:/out:z" -w /w "$INSTALLER_IMG" "$@"
  }
fi

log "Transpiling Butane -> Ignition"
run_butane --strict --files-dir "$W/files" "$W/config.bu" > "$WORK/config.ign"
[[ -s "$WORK/config.ign" ]] || die "butane produced an empty config"

log "Downloading Fedora CoreOS $STREAM live ISO"
run_installer download -s "$STREAM" -p metal -f iso -C "$O"
BASE_ISO="$(ls -t "$OUTDIR"/fedora-coreos-*-live*.iso | head -1)"
log "Base image: $(basename "$BASE_ISO")"

OUT_ISO="$OUTDIR/t2-coreos-installer.iso"
rm -f "$OUT_ISO"

CUSTOMIZE_ARGS=(
  iso customize
  --dest-ignition "$W/config.ign"
  --dest-device "$DISK"
  -o "$O/$(basename "$OUT_ISO")"
)
for k in $LIVE_KARGS; do CUSTOMIZE_ARGS+=(--live-karg-append "$k"); done
CUSTOMIZE_ARGS+=("$O/$(basename "$BASE_ISO")")

log "Building self-installing ISO (target: $DISK)"
run_installer "${CUSTOMIZE_ARGS[@]}"

cat <<EOF

$(log "Done")

  ISO:    $OUT_ISO
  Config: $BU        (rendered, for inspection)
  Target: $DISK      -- WILL BE ERASED WITHOUT PROMPTING
  LUKS:   $LUKS_MODE${TANG_URL:+ + tang at $TANG_URL}$( [[ "$TANG_MDNS" == "1" ]] && echo " (mDNS resolver in initramfs)" )

Write it with:  sudo dd if=$OUT_ISO of=/dev/diskN bs=4M status=progress oflag=direct
EOF
