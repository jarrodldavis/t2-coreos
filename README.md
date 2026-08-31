# t2-coreos

Builds a self-installing Fedora CoreOS ISO for an Intel T2 MacBook Pro. The installed system starts from stock Fedora CoreOS and applies the t2linux kernel and packages with rpm-ostree on first boot.

## Requirements

- Python 3
- Podman
- curl

## Build

`--ssh-key` and `--tang-url` are required:

```bash
./build-iso \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --hostname t2-macbook \
    --disk /dev/nvme0n1 \
    --tang-url http://tang-server.local:7500
```

The installer runs automatically against the selected disk. Outputs are written under `out/`:

```text
out/t2-coreos-installer.iso
out/t2-fcos.bu
out/staging/
```

## Fedora CoreOS version selection

The builder selects the newest entry in the FCOS release index whose Fedora major has an enabled x86_64 chroot in the T2 COPR. The selected version is used for the live ISO, and the helper RPM is built against the matching Fedora major.

Downloaded base ISOs are cached in `out/` by exact FCOS version.

## LUKS and Tang

Root encryption uses Butane's `boot_device.luks` support with Tang. The builder embeds the Tang advertisement and derives its signing-key thumbprint.

mDNS and `systemd-resolved` are included in the initramfs so `.local` Tang URLs resolve during boot. The internal T2 CDC-NCM interface is excluded from NetworkManager management.

A recovery passphrase can be enrolled manually after installation.

## T2 enablement

On first boot, `t2-enablement.service`:

1. installs the FCOS dracut sysusers helper;
2. applies the t2linux kernel override;
3. installs the configured T2 packages;
4. enables rpm-ostree initramfs regeneration;
5. reboots into the T2 deployment.

Local and SSH logins remain behind the normal `systemd-user-sessions` boot gate until enablement completes.

Default T2 packages:

```text
t2fanrd
tiny-dfr
t2linux-audio
systemd-resolved
```

Repeat `--t2-package PACKAGE` to replace the defaults. `systemd-resolved` is always included.

The generated initramfs force-loads:

```text
t2bce_dma
t2bce_core
t2bce_vhci
```

## Lid behavior

Lid closure does not suspend the machine. `t2-lid-display.service` powers down the internal display backlight while the lid is closed and restores it when opened. It ignores the Touch Bar's `appletb_backlight` device.

## Console and live installer

The live and installed systems use `latarcyrheb-sun32`. `rd.vconsole.font=latarcyrheb-sun32` applies the font during initramfs startup; the earliest kernel messages still use the kernel's built-in font.

The live installer adds:

```text
rd.driver.blacklist=applesmc
modprobe.blacklist=applesmc
systemd.debug_shell=1
```

The debug shell is on tty9. The live journal follows on tty8.

## Project layout

```text
build-iso                 build entry point
config/                   Butane templates
files/common/             installed system files
files/dracut/             dracut helper source
installer/                live installer hook
packaging/                helper RPM spec
templates/                configuration templates
out/staging/              rendered build inputs
```
