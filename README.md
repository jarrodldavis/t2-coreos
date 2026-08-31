# t2-coreos

Builds a self-installing Fedora CoreOS ISO for an Intel T2 MacBook Pro. Installation starts from stock Fedora CoreOS, then applies the t2linux kernel and userspace packages with rpm-ostree on first boot.

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
```

The generated ISO installs automatically to the configured disk and erases its existing contents. Use `--disk`, `--hostname`, or `--stream` to override the defaults.

Build output includes:

```text
out/t2-coreos-installer.iso
out/t2-fcos.bu
out/staging/
```

Downloaded FCOS ISOs are cached by exact release version.

## Version compatibility

The builder selects the newest released FCOS version in the requested stream whose Fedora major has an enabled x86_64 chroot in `sharpenedblade/t2linux`. The helper RPM is built against that same Fedora major.

Installed systems keep normal Zincati update behavior through a local Cincinnati filter. The filter preserves Fedora's update graph but hides update edges targeting Fedora majors that the T2 COPR does not support. If the graph or compatibility data cannot be validated, Zincati retries later rather than updating unfiltered.

Zincati uses a configured Saturday 03:00–05:00 maintenance window for update reboots.

## Installation and first boot

The installer configures:

- LUKS root encryption unlocked through Tang;
- mDNS and `systemd-resolved` in the initramfs for `.local` Tang URLs;
- the configured hostname and SSH key;
- a large console font;
- tty8 for the live journal and tty9 for the systemd debug shell.

On first boot, `t2-enablement.service` installs the T2 kernel and packages, regenerates the initramfs, and reboots into the resulting deployment. Local and SSH logins remain behind the normal `systemd-user-sessions` boot gate until this completes.

Default T2 packages are:

```text
t2fanrd
tiny-dfr
t2linux-audio
systemd-resolved
```

Repeat `--t2-package PACKAGE` to replace the default package set. `systemd-resolved` is always included.

## Lid behavior

Closing the lid does not suspend the system. `t2-lid-display.service` turns off the internal display backlight while the lid is closed and restores it when opened. The Touch Bar backlight is ignored.

## Project layout

```text
build-iso       build entry point
config/         Butane templates
files/common/   installed system files
files/dracut/   dracut helper source
installer/      live installer hook
packaging/      helper RPM spec
templates/      source configuration templates
```
