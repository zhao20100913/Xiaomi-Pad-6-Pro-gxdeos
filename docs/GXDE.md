# GXDE OS on the Xiaomi Pad 6 Pro (liuqin)

This document describes the GXDE OS port layered on top of the mainline
Ubuntu image pipeline. GXDE OS (https://www.gxde.top/) is a Debian 13
("trixie") based desktop; this port keeps the project's boot chain, device
layer and installer, and replaces the Ubuntu/GNOME userspace with Debian +
GXDE.

The work is driven by [`.github/workflows/gxde.yml`](../.github/workflows/gxde.yml).

## What is built, and by whom

| job | runner | produces |
| --- | --- | --- |
| `kernel` | `ubuntu-24.04` | the locked mainline kernel (`kernel/source.json` commit), modules, DTB |
| `gxde-rootfs` | `ubuntu-24.04` + qemu-user | Debian trixie + GXDE arm64 root, kernel modules, device layer when available |
| `image` | self-hosted `liuqin-images` | `boot.img`, `installer.img`, `rootfs.tar.gz`, `bundle.json` |

The first two jobs run on GitHub-hosted runners and use only public inputs.
The `image` job needs the **non-redistributable stock inputs** (sensor stack,
fingerprint provider, stock DTBO/vendor_boot DTBs) and is therefore gated
exactly like the upstream image workflow: `vars.LIUQIN_IMAGE_CI == 'enabled'`,
`refs/heads/main`, and a runner labelled `liuqin-images` with
`LIUQIN_IMAGE_INPUTS` pointing at the prepared `inputs.json`.

The hosted `gxde-rootfs` job therefore produces a *base* root: Debian + GXDE +
kernel modules, without the device-support/sensors/firmware debs. That root is
adequate to inspect the desktop and to develop against, but it is **not** a
bootable image: the initramfs native profile is fail-closed and requires the
project-owned device layer (contract hashes, firmware, sensors).

## Why gdm3 and not lightdm

GXDE normally ships `lightdm` (or the optional `gxdm`). This port does not use
either, for one reason: the boot chain is a contract.

The initramfs `native` profile admits a root only when, among other things:

- `/etc/liuqin-native-root` matches its pinned hash,
- every file in the native root contract is present and hashed,
- `/etc/systemd/system/display-manager.service` is a symlink to
  `/lib/systemd/system/gdm3.service`,
- `/usr/lib/systemd/systemd`, `/usr/sbin/gdm3` and `/usr/bin/gnome-shell` are
  executable, and systemd runs under `chroot`.

`gdm3` and `gnome-shell` are hard requirements of that profile. Rather than
weaken or fork a fail-closed boot path (a mistake there bricks the device and
cannot be validated without hardware), the GXDE session is started **through
gdm3**:

- `gdm3` is the greeter and the session launcher;
- `startgxde` (from `gxde-desktop`) is selected as the session via
  `/etc/liuqin-gxde-session`, written during assembly;
- `lightdm`/`gxdm` are masked in `/etc/systemd/system`;
- `device/gxde-overlay/etc/gdm3/custom.conf` disables Wayland (GXDE is X11) and
  enables autologin for the desktop user.

The result is the GXDE desktop (panel, dock, launcher, control center, file
manager) with a GNOME greeter. A dedicated `gxde` initramfs profile
(lightdm/startgxde + its own marker and contract pins) is the natural follow-up
but is deliberately **not** part of this change.

## Assembly steps

`tools/gxde/build-gxde-rootfs.sh` has one stage per concern:

```
bootstrap  mmdebstrap a Debian trixie minbase arm64 root
desktop    add Debian trixie sources, install gxde-source, install GXDE + gdm3
device     install the liuqin device debs (needs the stock-built inputs)
assemble   overlay, units, marker, session choice, user, identity cleanup
manifest   write gxde-rootfs.{manifest,hashes,identity} via root-manifest.py
pack       deterministic rootfs.tar.zst
check      assert the root is internal-consistent (gdm3, session, marker, …)
```

`tools/gxde/assemble-gxde-image.sh` consumes a GXDE root plus the prepared
stock inputs and produces the same bundle format the upstream installer
understands (`bundle.json`, `boot.img`, `installer.img`, `rootfs.tar.gz`,
`install.py`, `liuqin_layout.py`). The bundle status is `OFFLINE_ASSEMBLED`:
it was not device-tested, so `install-liuqin.py` requires
`--allow-unverified` to flash it.

## Changes to upstream tooling

One minimal, default-preserving patch to `tools/build-liuqin-debs.sh`:

- `LIUQIN_DEVICE_SUPPORT_DEPS` overrides the `device-support` Depends line.
  The default is unchanged (Ubuntu names); the GXDE build passes
  `libasound2t64 (>= 1.2), python3-gi, python3-pyudev, init-system-helpers,
  libglib2.0-bin` because Debian has no `gnome-control-center (>= 1:50.0)`.
- `POWER_SETTINGS_BINARY` may now be empty: the Ubuntu-rebuilt
  `gnome-control-center` is only installed when the binary is present, while
  the power GSettings schema is still compiled — the GXDE build uses Debian's
  own `gnome-control-center`, and the native contract only pins the schema
  files under `/usr/share/liuqin/power/`.

## Running it

On a machine with root and an arm64 binfmt handler:

```sh
sudo tools/gxde/build-gxde-rootfs.sh all
```

or via Actions → "GXDE OS (liuqin)" → Run workflow. `gxde_mirror` selects the
package mirror (`https://repo.gxde.top/gxde-os/lizhi` by default,
`https://mirrors.cernet.edu.cn/GXDE/gxde-os/lizhi` is a useful fallback).
`install_spark_store` adds the GXDE app store (~85 MB).

For the flashable bundle on the image runner:

```sh
LIUQIN_IMAGE_INPUTS=/opt/liuqin/inputs.json \
GXDE_ROOT=$PWD/out/gxde/rootfs KERNEL_OUT=$PWD/out/kernel \
KERNEL_SOURCE=$PWD/linux-sm8450-liuqin \
sudo -E tools/gxde/assemble-gxde-image.sh
```

## Known limitations

- No hardware validation has been done for this port; the boot path, the GXDE
  session and touch/rotation behaviour are unverified on a device.
- `gxde-desktop-extra` pulls a large dependency set; if the mirror is slow the
  rootfs job is the long pole. `GXDE_EXTRA_PACKAGES=` disables it.
- The hosted root has no device layer, so `check` on a hosted-built root passes
  only the distro-level assertions, and `manifest` reports
  `device_layer=no`.
- GXDE and KDE must not be installed together; nothing here installs KDE.
