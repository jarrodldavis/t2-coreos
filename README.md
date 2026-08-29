# t2-coreos

Builds a self-installing Fedora CoreOS ISO for an Intel T2 MacBook Pro. The installed system uses the stock Fedora CoreOS image, then applies the t2linux kernel as a persistent rpm-ostree override on first boot.

## Project layout

```text
.
├── build-iso
├── config/
│   ├── destination.bu.in
│   └── fragments/
│       ├── luks-enroll-unit.bu
│       ├── luks-install-key.bu
│       └── mdns-overrides.bu
├── files/
│   ├── common/
│   │   ├── etc/
│   │   │   ├── dracut.conf.d/t2linux-modules.conf
│   │   │   ├── modprobe.d/t2-eth-blocklist.conf
│   │   │   ├── systemd/logind.conf.d/10-t2-no-suspend.conf
│   │   │   ├── systemd/system/luks-enroll.service
│   │   │   ├── systemd/system/t2-enablement.service
│   │   │   └── zincati/config.d/55-updates-strategy.toml
│   │   └── usr/local/bin/
│   │       ├── luks-enroll
│   │       └── t2-enablement
│   └── mdns/
│       └── etc/
│           ├── NetworkManager/conf.d/10-mdns.conf
│           ├── dracut.conf.d/40-mdns.conf
│           ├── nsswitch.conf
│           └── systemd/resolved.conf.d/10-mdns.conf
├── installer/
│   └── pre-install.sh.in
└── templates/
    └── t2linux.repo.in
```

`build-iso` is orchestration only. The installed filesystem content lives under `files/`, the Butane structure lives under `config/`, and the live-installer hook lives under `installer/`.

The builder stages the selected filesystem trees into a temporary directory and embeds them with Butane `storage.trees`. The rendered Butane config is left in the output directory for inspection.

## Requirements

By default:

- Python 3
- `curl`
- Podman

The builder uses:

- `quay.io/coreos/butane:release`
- `quay.io/coreos/coreos-installer:release`

Set `NATIVE=1` to use locally installed `butane` and `coreos-installer` instead of Podman.

## Build

`SSH_KEY` is required and can be either a public-key filename or the literal public key:

```bash
SSH_KEY=~/.ssh/id_ed25519.pub ./build-iso
```

For example:

```bash
SSH_KEY=~/.ssh/id_ed25519.pub \
FCOS_HOSTNAME=t2-macbook \
DISK=/dev/nvme0n1 \
./build-iso
```

The default output directory is `./out`:

```text
out/fedora-coreos-*-live-iso.x86_64.iso
out/t2-fcos.bu
out/t2-coreos-installer.iso
```

The installer ISO automatically installs to `DISK` without confirmation.

## LUKS

`LUKS_MODE=enroll` is the default. Ignition creates the root LUKS volume using a random temporary key. On first boot, `luks-enroll.service` prompts for a permanent passphrase, confirms that a second keyslot exists, removes the temporary key, and deletes `/etc/luks-install.key`.

To embed the permanent passphrase instead:

```bash
LUKS_MODE=embed \
LUKS_PASSPHRASE='...' \
SSH_KEY=~/.ssh/id_ed25519.pub \
./build-iso
```

In `embed` mode the passphrase is present in the generated installer material.

## Tang

Tang is optional. Set both the URL and signing-key thumbprint:

```bash
TANG_URL=http://tang-server.local:7500 \
TANG_THUMBPRINT='<tang-signing-key-thumbprint>' \
SSH_KEY=~/.ssh/id_ed25519.pub \
./build-iso
```

`TANG_MDNS=auto` is the default. A `.local` Tang URL enables the files under `files/mdns/`, adds `systemd-resolved` to the first-boot package list, and tells rpm-ostree to include `/etc/nsswitch.conf` when regenerating the initramfs.

Set `TANG_MDNS=0` or `TANG_MDNS=1` to override the automatic choice.

## T2 enablement

`t2-enablement.service` runs after networking is online and after LUKS enrollment has completed. It:

1. enables rpm-ostree initramfs regeneration;
2. registers a repository-backed kernel override from the `sharpenedblade/t2linux` COPR;
3. layers the configured T2 userspace packages;
4. records `/var/lib/t2-enablement.stamp`;
5. reboots into the pending T2 deployment.

The default userspace packages are:

```text
t2fanrd tiny-dfr t2linux-audio
```

Override them with `T2_PKGS`. When mDNS Tang support is enabled, `systemd-resolved` is appended automatically.

## Build variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `SSH_KEY` | required | Public key file or literal key |
| `DISK` | `/dev/nvme0n1` | Automatic install target |
| `STREAM` | `stable` | FCOS stream |
| `FCOS_HOSTNAME` | `t2mac` | Installed hostname |
| `OUTDIR` | `./out` | Build output directory |
| `LUKS_MODE` | `enroll` | `enroll` or `embed` |
| `LUKS_PASSPHRASE` | empty | Required with `LUKS_MODE=embed` |
| `TANG_URL` | empty | Optional Tang URL |
| `TANG_THUMBPRINT` | empty | Required when `TANG_URL` is set |
| `TANG_MDNS` | `auto` | `auto`, `0`, or `1` |
| `T2_PKGS` | `t2fanrd tiny-dfr t2linux-audio` | Layered T2 packages |
| `LIVE_KARGS` | empty | Extra live-installer kernel arguments |
| `LIVE_DEBUG_SHELL` | `1` | Enable the live debug shell on tty9 |
| `LIVE_VERBOSE` | `1` | Forward live journal output to the console |
| `COPR_GPG_KEY_FILE` | empty | Use a local COPR public key instead of downloading it |
| `NATIVE` | `0` | Use native Butane/coreos-installer when set to `1` |

## Installer diagnostics

With the defaults, the live environment enables the systemd debug shell on tty9 and forwards the journal to the console. If installation fails, inspect the installer unit with:

```bash
journalctl -b -u coreos-installer --no-pager
```
