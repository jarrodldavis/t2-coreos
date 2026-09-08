# t2-coreos

Builds a self-installing Fedora CoreOS ISO for Intel T2 MacBook Pros. The ISO installs stock Fedora CoreOS, then enables T2 hardware support with rpm-ostree on the first installed boot.

## Requirements

- Python 3
- Podman
- curl

## Build

```bash
./build-iso \
    --ssh-key ~/.ssh/id_ed25519.pub \
    --tang-url http://tang-server.local:7500
```

Defaults:

```text
hostname: t2mac
disk:     /dev/nvme0n1
stream:   stable
output:   out/
timezone: builder system timezone
```

The generated ISO installs automatically to the configured disk and erases its existing contents. Use `--disk`, `--hostname`, `--stream`, or `--timezone` to override the defaults. `--timezone` accepts an IANA timezone such as `America/Denver`.

The installer ISO is written to:

```text
out/t2-coreos-installer.iso
```

Downloaded FCOS ISOs are cached by exact release version.

## Installation

The installer configures:

- LUKS root encryption unlocked through Tang;
- mDNS and `systemd-resolved` in the initramfs for `.local` Tang URLs;
- the configured hostname and SSH key;
- a large console font;
- tty8 for the live journal and tty9 for the systemd debug shell;
- a fresh UEFI NVRAM boot entry for the installed EFI system partition.

The post-install boot entry points to `\EFI\fedora\shimx64.efi`, avoiding stale EFI entries when the installer recreates the partition table.

## First boot

`t2-enablement.service` runs before user sessions on the first installed boot. It:

1. fetches the upstream t2linux firmware helper and installs the recommended macOS Wi-Fi/Bluetooth firmware, falling back to Sonoma when necessary;
2. stages the T2 kernel and packages with rpm-ostree;
3. regenerates the initramfs;
4. reboots into the completed deployment.

Wired Internet is required during first boot. If enablement fails, user sessions are still allowed so the system remains accessible for debugging.

Default optional T2 packages are:

```text
t2fanrd
tiny-dfr
t2linux-audio
```

`systemd-resolved` and `NetworkManager-wifi` are always layered. Repeat `--t2-package PACKAGE` to replace the optional package set.

## Updates

The builder selects the newest released FCOS version in the requested stream whose Fedora major is supported by `sharpenedblade/t2linux`.

Zincati keeps its normal update behavior through a local Cincinnati filter that removes update edges targeting unsupported Fedora majors. Update reboots are allowed Saturday 03:00–05:00 in the configured system timezone.

## Lid behavior

Closing the lid does not suspend the system. `t2-lid-display.service` turns off the internal display backlight while the lid is closed and restores it when opened. The Touch Bar backlight is ignored.

## Project layout

```text
build-iso       build entry point
config/         Butane templates
files/common/   installed system files
files/dracut/   dracut helper source
installer/      live installer hooks
packaging/      helper RPM spec
templates/      source configuration templates
```
