# t2-coreos

Builds Fedora CoreOS ISOs for an Intel T2 MacBook Pro.

Normal mode produces a self-installing ISO. `--diagnostic` produces a non-installing live ISO. The installed system starts from stock Fedora CoreOS and applies the t2linux kernel and userspace packages with rpm-ostree on first boot.

## Requirements

- Python 3
- Podman
- `curl` for installer builds

The default container images are:

- `quay.io/coreos/butane:release`
- `quay.io/coreos/coreos-installer:release`

Use `--native` to use local `butane` and `coreos-installer` binaries instead.

## Build an installer ISO

`--ssh-key` and `--tang-url` are required:

```bash
./build-iso \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --hostname t2-macbook \
    --disk /dev/nvme0n1 \
    --tang-url http://tang-server.local:7500
```

The installer runs automatically against the selected disk.

Outputs are written under `out/`, including:

```text
out/t2-coreos-installer.iso
out/t2-fcos.bu
out/staging/
```

Run `./build-iso --help` for all options.

## LUKS and Tang

Root encryption uses Butane's native `boot_device.luks` configuration with Tang. Ignition resizes the root partition to fill the disk during provisioning.

The builder embeds the Tang advertisement for offline provisioning. If `--tang-thumbprint` is omitted, it derives the signing-key thumbprint from the advertisement.

`.local` Tang URLs enable the mDNS configuration automatically. Override this with `--tang-mdns=on` or `--tang-mdns=off`.
mDNS Tang boots enable initramfs DHCP networking automatically. The internal T2 CDC-NCM interface is marked as non-NetworkManager-owned so it does not participate in DHCP or wait-online.

A recovery passphrase can be enrolled manually after installation.

## T2 enablement

On first boot, `t2-enablement.service`:

1. configures the `sharpenedblade/t2linux` repository;
2. applies a persistent kernel override;
3. layers the configured T2 packages;
4. layers the FCOS dracut sysusers helper when mDNS Tang support is enabled;
5. enables rpm-ostree initramfs regeneration.

The service reboots into the T2 deployment after successful enablement.

User logins are held until first-boot T2 enablement succeeds and triggers a reboot.

Default T2 packages:

```text
t2fanrd
tiny-dfr
t2linux-audio
```

Repeat `--t2-package PACKAGE` to replace the default set.

The generated initramfs force-loads:

```text
t2bce_dma
t2bce_core
t2bce_vhci
```

When mDNS Tang support is enabled, `systemd-resolved` is also layered and included in the initramfs configuration.

## Live installer settings

The installer live environment adds:

```text
rd.driver.blacklist=applesmc
modprobe.blacklist=applesmc
```

This prevents the stock `applesmc` driver from blocking udev on T2 hardware. The blacklist is not added to the installed system.

The systemd debug shell is available on tty9.

## Diagnostic ISO

Build a non-installing live ISO with SSH access:

```bash
./build-iso \
    --diagnostic \
    --ssh-key ~/.ssh/id_ed25519.pub
```

Output:

```text
out/t2-coreos-diagnostic.iso
```

Tang is not required in diagnostic mode. The default hostname is `t2-coreos-live`, SSH is enabled for `core`, and the systemd debug shell is available on tty9.

Add live kernel arguments with repeated `--live-karg` options:

```bash
./build-iso \
    --diagnostic \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --live-karg rd.udev.log_level=debug \
    --live-karg udev.log_level=debug
```

`--diagnostic-console-log` follows the journal on tty8.

## Project layout

```text
build-iso                 build entry point
config/                   Butane templates and fragments
files/common/             files installed on every system
files/mdns/               files used for mDNS Tang support
installer/                live installer hook
templates/                generated configuration templates
out/staging/              rendered build inputs
```
