#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Build a Debian 13 "trixie" + GXDE OS arm64 root filesystem for the Xiaomi
# Pad 6 Pro (liuqin), on top of this project's device layer.
#
#   bootstrap  mmdebstrap a minimal trixie arm64 root (needs root + binfmt)
#   desktop    Debian + the GXDE repository, gdm3, xorg, pipewire, the GXDE
#              desktop packages
#   device     install the liuqin device .deb set (built by
#              tools/build-liuqin-debs.sh from a stock dump) or, without it,
#              only the matching kernel module tree
#   assemble   BlueZ policy, unit links, native-root marker, GXDE session
#              selection, the tablet account, display-manager arbitration
#   manifest   root manifest + the native-root.hashes file the boot contract
#              consumes
#   pack       deterministic rootfs.tar.zst
#   check      in-chroot sanity checks (systemd, GXDE session, gdm3)
#   all        every stage above
#
# The result is a root in the shape the project's `native` initramfs profile
# admits: gdm3 stays the display manager because the profile and the sealed
# contract require /usr/sbin/gdm3, /usr/bin/gnome-shell and
# display-manager.service -> gdm3.service.  The GXDE session is what runs after
# gdm3 logs the tablet user in; lightdm and gxdm are masked so an upgrade
# cannot steal the seat.  Removing that requirement is a boot-path change and is
# deliberately left to a later, device-tested revision.
#
# This script never edits the device debs, the initramfs or the contract
# generator.  It exists so a normal Ubuntu 24.04 runner (with qemu binfmt) or a
# Debian host can produce the GXDE root; the stock-input device layer is still
# the project's own build.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out_dir=${OUT_DIR:-"$project_root/out/gxde"}
root=${GXDE_ROOT:-"$out_dir/rootfs"}
debian_suite=${GXDE_DEBIAN_SUITE:-trixie}
debian_mirror=${GXDE_DEBIAN_MIRROR:-http://deb.debian.org/debian}
debian_security=${GXDE_DEBIAN_SECURITY:-http://security.debian.org/debian-security}
gxde_mirror=${GXDE_MIRROR:-https://repo.gxde.top/gxde-os/lizhi}
gxde_fallback_mirror=${GXDE_FALLBACK_MIRROR:-https://mirrors.cernet.edu.cn/GXDE/gxde-os/lizhi}
gxde_source_url=${GXDE_SOURCE_URL:-https://repo.gxde.top/gxde-os/lizhi/g/gxde-source/gxde-source_1.1.11_all.deb}
gxde_source_sha256=${GXDE_SOURCE_SHA256:-}
gxde_source_deb=${GXDE_SOURCE_DEB:-}
gxde_packages=${GXDE_PACKAGES:-gxde-desktop}
gxde_extra_packages=${GXDE_EXTRA_PACKAGES:-gxde-desktop-extra}
gxde_user=${GXDE_USER:-liuqin}
gxde_password=${GXDE_PASSWORD:-liuqin}
gxde_hostname=${GXDE_HOSTNAME:-liuqin}
gxde_timezone=${GXDE_TIMEZONE:-Asia/Shanghai}
gxde_locale=${GXDE_LOCALE:-zh_CN.UTF-8}
gxde_install_spark_store=${GXDE_INSTALL_SPARK_STORE:-0}
device_debs_dir=${DEVICE_DEBS_DIR:-}
kernel_modules_dir=${KERNEL_MODULES_DIR:-}
overlay=$project_root/device/gxde-overlay
source_date_epoch=${SOURCE_DATE_EPOCH:-$(git -C "$project_root" log -1 --format=%ct 2>/dev/null || echo 1700000000)}

base_include=systemd,systemd-sysv,udev,dbus,ca-certificates,curl,gnupg,apt-utils,dpkg-dev,kmod,zstd,xz-utils,sudo,locales,tzdata,file,less,procps,psmisc,iproute2,iputils-ping,network-manager,openssh-server,e2fsprogs,rsync,python3,python3-apt,console-setup,keyboard-configuration,nano,usbutils,pciutils,whiptail,rsyslog

# Packages every GXDE tablet needs.  gdm3 and gnome-shell are not cosmetic:
# the `native` root profile refuses to open a root without them, so they are
# part of the port's contract, not a GNOME preference.
core_packages="gdm3 gnome-shell xserver-xorg xwayland x11-xserver-utils \
mesa-vulkan-drivers libgl1-mesa-dri libegl-mesa0 libgbm1 \
pipewire pipewire-pulse wireplumber libspa-0.2-bluetooth alsa-ucm-conf \
bluez network-manager upower systemd-zram-generator gnome-keyring polkitd pkexec \
fonts-noto-cjk fonts-noto-color-emoji fonts-symbola xdg-user-dirs xdg-utils \
sudo locales tzdata zstd unzip"

# Best-effort extras: a missing optional package must not fail the port.
optional_packages="iio-sensor-proxy libqrtr1 libprotobuf-c1 python3-gi python3-pyudev \
power-profiles-daemon libinput-tools cups-daemon avahi-daemon"

die() { printf 'gxde-rootfs: %s\n' "$*" >&2; exit 1; }
say() { printf 'gxde-rootfs: %s\n' "$*" >&2; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

case $out_dir in
/*) ;;
*) die "output must be an absolute path (got $out_dir)" ;;
esac
case $out_dir in */../*|*/..|*/./*|*/.|*/) die 'output path must not contain traversal' ;; esac
case $root in
"$out_dir"/rootfs) ;;
*)
	[ "${GXDE_ALLOW_FOREIGN_ROOT:-0}" = 1 ] ||
		die "refusing to manage $root (set GXDE_ALLOW_FOREIGN_ROOT=1 if that is the intended root)"
	;;
esac
[ "${root#/}" != "$root" ] || die 'the root must be an absolute path'
[ "$root" != / ] || die 'refusing to use / as the root'

mounts_up=0
mount_root() {
	[ "$mounts_up" = 1 ] && return 0
	mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/dev/pts"
	for fs in proc sys dev; do
		mountpoint -q "$root/$fs" || mount --bind "/$fs" "$root/$fs" ||
			die "could not bind /$fs into the root"
	done
	mountpoint -q "$root/dev/pts" || mount --bind /dev/pts "$root/dev/pts" 2>/dev/null || true
	mounts_up=1
}
unmount_root() {
	[ "$mounts_up" = 1 ] || return 0
	umount -l "$root/dev/pts" 2>/dev/null || true
	for fs in dev sys proc; do umount -l "$root/$fs" 2>/dev/null || true; done
	mounts_up=0
}
trap 'unmount_root' EXIT INT TERM HUP

in_root() {
	mount_root
	chroot "$root" /usr/bin/env -i \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		HOME=/root TERM=dumb LANG=C.UTF-8 LC_ALL=C.UTF-8 \
		DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
		SHELL=/bin/sh "$@"
}

need_root() { [ "$(id -u)" = 0 ] || die 'this stage must run as root'; }

# ---------------------------------------------------------------------------
# bootstrap
# ---------------------------------------------------------------------------
stage_bootstrap() {
	need_root
	command -v mmdebstrap >/dev/null || die 'mmdebstrap is required (apt install mmdebstrap)'
	if [ "$(dpkg --print-architecture 2>/dev/null || uname -m)" != arm64 ]; then
		[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] ||
			die 'arm64 binfmt is not registered; install qemu-user-static + binfmt-support, or run "docker run --privileged --rm tonistiigi/binfmt --install arm64"'
	fi
	say "bootstrapping Debian $debian_suite from $debian_mirror"
	rm -rf "$root"
	mkdir -p "$(dirname "$root")"
	mmdebstrap \
		--architectures=arm64 \
		--variant=minbase \
		--components=main,contrib,non-free,non-free-firmware \
		--include="$base_include" \
		--aptopt='Acquire::Retries "3"' \
		--aptopt='Acquire::http::Timeout "30"' \
		"$debian_suite" "$root" "$debian_mirror"
	[ -x "$root/usr/lib/systemd/systemd" ] || die 'bootstrap produced no systemd'
	[ -f "$root/etc/resolv.conf" ] || cp /etc/resolv.conf "$root/etc/resolv.conf"
	printf '%s\n' "$gxde_hostname" >"$root/etc/hostname"
	cat >"$root/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$gxde_hostname
::1		localhost ip6-localhost ip6-loopback
EOF
}

# ---------------------------------------------------------------------------
# desktop
# ---------------------------------------------------------------------------
write_debian_sources() {
	mkdir -p "$root/etc/apt/sources.list.d"
	rm -f "$root/etc/apt/sources.list"
	cat >"$root/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $debian_mirror
Suites: $debian_suite $debian_suite-updates $debian_suite-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $debian_security
Suites: $debian_suite-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

install_gxde_source() {
	mkdir -p "$out_dir/inputs"
	deb=$out_dir/inputs/gxde-source.deb
	if [ -n "$gxde_source_deb" ]; then
		[ -f "$gxde_source_deb" ] || die "GXDE_SOURCE_DEB is missing: $gxde_source_deb"
		cp "$gxde_source_deb" "$deb"
	else
		say "fetching the GXDE repository package from $gxde_source_url"
		curl -fsSL --retry 3 --max-time 300 -o "$deb" "$gxde_source_url" ||
			die "could not download $gxde_source_url"
	fi
	if [ -n "$gxde_source_sha256" ]; then
		[ "$(sha "$deb")" = "$gxde_source_sha256" ] ||
			die "GXDE repository package hash mismatch: $(sha "$deb")"
	else
		say "WARNING: GXDE_SOURCE_SHA256 is unset; pinning $(sha "$deb") is recommended"
	fi
	install -D -m 0644 "$deb" "$root/tmp/gxde-source.deb"
	in_root dpkg -i /tmp/gxde-source.deb || die 'the GXDE repository package did not install'
	rm -f "$root/tmp/gxde-source.deb"
	[ -f "$root/etc/apt/trusted.gpg.d/gxde.gpg" ] || die 'the GXDE signing key is missing'
	list=$root/etc/apt/sources.list.d/gxde.list
	[ -f "$list" ] || die 'the GXDE source list is missing'
	# GXDE writes its public flat repository; mirror overrides are local edits.
	sed -i "s|https://repo.gxde.top/gxde-os/lizhi|$gxde_mirror|g" "$list"
}

apt_update() {
	if ! in_root apt-get update; then
		if [ "$gxde_mirror" != "$gxde_fallback_mirror" ]; then
			say "apt update failed; retrying the GXDE part with $gxde_fallback_mirror"
			sed -i "s|$gxde_mirror|$gxde_fallback_mirror|g" \
				"$root/etc/apt/sources.list.d/gxde.list"
			in_root apt-get update || die 'apt update failed on every mirror'
		else
			die 'apt update failed'
		fi
	fi
}

stage_desktop() {
	need_root
	[ -x "$root/usr/bin/apt-get" ] || die 'run the bootstrap stage first'
	write_debian_sources
	install_gxde_source
	apt_update
	# gdm3 is the port's display manager; preseed it so a GXDE-pulled lightdm
	# does not win the shared/default-x-display-manager question.
	in_root /bin/sh -c "printf '%s\n' 'gdm3 shared/default-x-display-manager select gdm3' | debconf-set-selections"
	in_root /bin/sh -c "printf '%s\n' 'keyboard-configuration keyboard-configuration/layoutcode string us' | debconf-set-selections"
	say 'installing the base desktop'
	# shellcheck disable=SC2086
	in_root apt-get install -y --no-install-recommends $core_packages ||
		die 'the base desktop could not be installed'
	# shellcheck disable=SC2086
	if ! in_root apt-get install -y $optional_packages; then
		say 'WARNING: some optional tablet packages are unavailable on this mirror; continuing'
	fi
	say "installing GXDE ($gxde_packages)"
	# shellcheck disable=SC2086
	in_root apt-get install -y $gxde_packages || die 'GXDE could not be installed'
	# shellcheck disable=SC2086
	in_root apt-get install -y $gxde_extra_packages 2>/dev/null ||
		say 'WARNING: gxde-desktop-extra is not available; the base GXDE desktop is installed'
	[ -x "$root/usr/bin/startgxde" ] || [ -x "$root/usr/bin/dde-session" ] ||
		die 'no GXDE session binary was installed'
	if [ "$gxde_install_spark_store" = 1 ]; then
		say 'installing spark-store'
		in_root apt-get install -y spark-store || say 'WARNING: spark-store could not be installed'
	fi
	in_root locale-gen "$gxde_locale" en_US.UTF-8 || true
	in_root ln -sf "/usr/share/zoneinfo/$gxde_timezone" /etc/localtime || true
	printf '%s\n' "$gxde_timezone" >"$root/etc/timezone"
	in_root apt-get clean
	# Keep the package lists: the device stage may still have debs to install.
}

# ---------------------------------------------------------------------------
# device
# ---------------------------------------------------------------------------
stage_device() {
	need_root
	[ -x "$root/usr/bin/apt-get" ] || die 'run the bootstrap stage first'
	if [ -n "$device_debs_dir" ]; then
		[ -d "$device_debs_dir" ] || die "DEVICE_DEBS_DIR is missing: $device_debs_dir"
		set -- "$device_debs_dir"/liuqin-*.deb
		[ -f "$1" ] || die "no liuqin debs in $device_debs_dir"
		say "installing the liuqin device layer from $device_debs_dir"
		mkdir -p "$root/tmp/liuqin-debs"
		cp "$@" "$root/tmp/liuqin-debs/"
		# The distro ships generic firmware-atheros/qcom blobs at the same paths;
		# the device package is the authority on a liuqin image.
		in_root /bin/sh -c 'cd /tmp/liuqin-debs && apt-get install -y --allow-downgrades -o Dpkg::Options::=--force-overwrite ./*.deb' ||
			die 'the liuqin device layer did not install'
		rm -rf "$root/tmp/liuqin-debs"
		[ -f "$root/usr/share/liuqin/kernel.release" ] ||
			die 'the device layer installed no /usr/share/liuqin/kernel.release'
		[ -x "$root/usr/libexec/iio-sensor-proxy" ] ||
			say 'WARNING: the sensor stack is not installed in this root'
	else
		say 'WARNING: no DEVICE_DEBS_DIR; building a GXDE base root without the liuqin device layer'
	fi
	if [ -n "$kernel_modules_dir" ]; then
		src=$kernel_modules_dir
		[ -d "$src/lib/modules" ] || src=$kernel_modules_dir/modules
		[ -d "$src" ] || die "KERNEL_MODULES_DIR is missing: $kernel_modules_dir"
		say "installing kernel modules from $src"
		mkdir -p "$root/lib/modules"
		for release_dir in "$src"/lib/modules/*; do
			[ -d "$release_dir" ] || continue
			release=$(basename "$release_dir")
			cp -a "$release_dir" "$root/lib/modules/$release"
			in_root depmod -a "$release" || say "WARNING: depmod failed for $release"
		done
	fi
}

# ---------------------------------------------------------------------------
# assemble
# ---------------------------------------------------------------------------
link_unit() { # link_unit <wants dir> <unit>
	if [ -e "$root/etc/systemd/system/$2" ]; then
		target=../$2
	elif [ -e "$root/usr/lib/systemd/system/$2" ]; then
		target=/usr/lib/systemd/system/$2
	elif [ -e "$root/lib/systemd/system/$2" ]; then
		target=/lib/systemd/system/$2
	else
		say "skip unit link (not installed): $2"
		return 0
	fi
	mkdir -p "$root/etc/systemd/system/$1"
	ln -sfn "$target" "$root/etc/systemd/system/$1/$2"
	[ -L "$root/etc/systemd/system/$1/$2" ] || die "unit link failed: $1/$2"
}

ensure_gdm3_unit() {
	# Debian historically ships gdm3.service; newer gdm releases also install
	# gdm.service with an alias.  The sealed contract names gdm3.service, so
	# provide it when only the newer name exists.
	if [ ! -e "$root/lib/systemd/system/gdm3.service" ] &&
		[ ! -e "$root/usr/lib/systemd/system/gdm3.service" ]; then
		[ -e "$root/usr/lib/systemd/system/gdm.service" ] ||
			die 'the installed gdm does not provide gdm3.service or gdm.service'
		ln -sfn /usr/lib/systemd/system/gdm.service "$root/usr/lib/systemd/system/gdm3.service"
		say 'aliased gdm.service as gdm3.service for the native root contract'
	fi
}

choose_session() {
	mkdir -p "$out_dir/inputs"
	for dir in xsessions wayland-sessions; do
		[ -d "$root/usr/share/$dir" ] || continue
		for entry in "$root/usr/share/$dir"/*.desktop; do
			[ -f "$entry" ] || continue
			name=$(basename "$entry" .desktop)
			case $name in
			*[Gg][Xx][Dd][Ee]* | *[Dd][Dd][Ee]* | *[Dd]eepin* | *startgxde*)
				printf '%s\n' "$name" >"$out_dir/inputs/gxde-session"
				return 0
				;;
			esac
		done
	done
	# Fall back to the package's own session registration.
	for entry in "$root/usr/share/xsessions"/*.desktop "$root/usr/share/wayland-sessions"/*.desktop; do
		[ -f "$entry" ] || continue
		if grep -qE '^Exec=.*(startgxde|gxde-session|dde-session)' "$entry"; then
			basename "$entry" .desktop >"$out_dir/inputs/gxde-session"
			return 0
		fi
	done
	return 1
}

stage_assemble() {
	need_root
	mkdir -p "$out_dir/inputs"
	[ -x "$root/usr/bin/apt-get" ] || die 'run the bootstrap stage first'
	# --- overlay (files only, never ownership or setuid surprises) -----------
	if [ -d "$overlay" ]; then
		say "installing the GXDE overlay from $overlay"
		(cd "$overlay" && find . -type f -printf '%P\n' | LC_ALL=C sort) >"$out_dir/inputs/gxde-overlay.files"
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			mode=$(stat -c '%a' "$overlay/$rel")
			case $mode in 6??) mode=644 ;; 7??) mode=755 ;; esac
			# Overlay files may come from a filesystem without an exec bit
			# (e.g. a checkout on Android storage); a shebang means executable.
			[ "$(head -c 2 "$overlay/$rel")" != '#!' ] || mode=755
			install -D -m "$mode" -o 0 -g 0 "$overlay/$rel" "$root/$rel"
		done <"$out_dir/inputs/gxde-overlay.files"
	fi

	# --- BlueZ: the tablet has no hardware kill switch ----------------------
	bluez_conf=$root/etc/bluetooth/main.conf
	if [ -f "$bluez_conf" ]; then
		bluez_tmp=$bluez_conf.liuqin.$$
		awk '
BEGIN { in_policy=0; saw_policy=0; emitted=0 }
/^\[Policy\][[:space:]]*$/ {
	if (in_policy && !emitted) print "AutoEnable=true"
	in_policy=1; saw_policy=1; emitted=0; print; next
}
/^\[[^]]+\][[:space:]]*$/ {
	if (in_policy && !emitted) print "AutoEnable=true"
	in_policy=0; print; next
}
in_policy && /^[#;]?[[:space:]]*AutoEnable[[:space:]]*=/ {
	if (!emitted) print "AutoEnable=true"
	emitted=1; next
}
{ print }
END {
	if (in_policy && !emitted) print "AutoEnable=true"
	if (!saw_policy) exit 42
}
' "$bluez_conf" >"$bluez_tmp" && chown 0:0 "$bluez_tmp" && chmod 0644 "$bluez_tmp" &&
			mv "$bluez_tmp" "$bluez_conf" ||
			{ rm -f "$bluez_tmp"; say 'WARNING: no unambiguous BlueZ [Policy] section; left untouched'; }
	fi

	# --- display manager: gdm3 owns the seat --------------------------------
	ensure_gdm3_unit
	for unit in lightdm gxdm; do
		if [ -e "$root/usr/lib/systemd/system/$unit.service" ] ||
			[ -e "$root/lib/systemd/system/$unit.service" ]; then
			ln -sfn /dev/null "$root/etc/systemd/system/$unit.service"
			say "masked $unit.service (gdm3 is the display manager on this port)"
		fi
	done
	ln -sfn /lib/systemd/system/gdm3.service "$root/etc/systemd/system/display-manager.service"
	[ "$(readlink "$root/etc/systemd/system/display-manager.service")" = /lib/systemd/system/gdm3.service ] ||
		die 'display-manager.service does not point at gdm3'
	ln -sfn /usr/lib/systemd/system/graphical.target "$root/etc/systemd/system/default.target"

	# --- the native profile's device units ----------------------------------
	link_unit basic.target.requires liuqin-gnome-storage-guard.service
	link_unit multi-user.target.wants liuqin-mipps-battery-auth.service
	link_unit multi-user.target.wants liuqin-slpi.service
	link_unit multi-user.target.wants liuqin-power-keyd.service
	link_unit graphical.target.wants liuqin-backlight-default.service
	link_unit sysinit.target.wants liuqin-physical-platform.service
	link_unit multi-user.target.wants liuqin-gxde-firstboot.service

	# --- the contract markers ------------------------------------------------
	# The initramfs native profile pins /etc/liuqin-native-root by content hash;
	# this file is not optional and is not produced by any package.
	printf 'liuqin-native-root-v1\n' >"$root/etc/liuqin-native-root"
	chown 0:0 "$root/etc/liuqin-native-root"
	chmod 0644 "$root/etc/liuqin-native-root"
	[ "$(sha "$root/etc/liuqin-native-root")" = \
		4fdae4f7a27af8b0d4a2bbc168c7f01c3c5c6b5e245fcc521389d662f8212c5b ] ||
		die 'the native-root marker does not match the initramfs pin'
	# The GXDE marker only gates the first-boot helper.
	printf 'liuqin-gxde-root-v1\n' >"$root/etc/liuqin-gxde-root"
	chown 0:0 "$root/etc/liuqin-gxde-root"
	chmod 0644 "$root/etc/liuqin-gxde-root"

	# --- account and session ------------------------------------------------
	choose_session || die 'could not identify a GXDE session file'
	session=$(cat "$out_dir/inputs/gxde-session")
	[ -n "$session" ] || die 'the GXDE session file is empty'
	printf 'session=%s\n' "$session" >"$root/etc/liuqin-gxde-session"
	if ! in_root id "$gxde_user" >/dev/null 2>&1; then
		groups=
		for group in audio video input render plugdev netdev bluetooth dialout; do
			in_root getent group "$group" >/dev/null 2>&1 && groups="$groups${groups:+,}$group"
		done
		say "creating the $gxde_user account (session: $session)"
		set -- useradd --create-home --uid 1000 --shell /bin/bash \
			--comment "$gxde_user"
		[ -z "$groups" ] || set -- "$@" --groups "$groups"
		in_root "$@" "$gxde_user" || die 'the tablet account could not be created'
		printf '%s:%s\n' "$gxde_user" "$gxde_password" | in_root chpasswd ||
			die 'the tablet account password could not be set'
	fi
	mkdir -p "$root/var/lib/AccountsService/users"
	printf '[User]\nSystemAccount=false\nXSession=%s\n' "$session" \
		>"$root/var/lib/AccountsService/users/$gxde_user"
	chown 0:0 "$root/var/lib/AccountsService/users/$gxde_user"
	chmod 0600 "$root/var/lib/AccountsService/users/$gxde_user"

	# --- first-boot identity ------------------------------------------------
	: >"$root/etc/machine-id"
	rm -f "$root/etc/ssh/ssh_host_"*_key "$root/etc/ssh/ssh_host_"*_key.pub
	rm -f "$root/var/lib/dbus/machine-id" 2>/dev/null || true
	ln -sfn /etc/machine-id "$root/var/lib/dbus/machine-id"
	rm -rf "$root/var/cache/apt/archives"/*.deb "$root/tmp"/*
	mkdir -p "$root/tmp" "$root/var/tmp"
	chmod 1777 "$root/tmp" "$root/var/tmp"
	say 'assemble complete'
}

# ---------------------------------------------------------------------------
# manifest / pack / check
# ---------------------------------------------------------------------------
kernel_release() {
	if [ -f "$root/usr/share/liuqin/kernel.release" ]; then
		cat "$root/usr/share/liuqin/kernel.release"
	elif [ -n "${KERNEL_RELEASE:-}" ]; then
		printf '%s\n' "$KERNEL_RELEASE"
	else
		printf 'unknown\n'
	fi
}

stage_manifest() {
	need_root
	unmount_root
	say 'writing root manifests'
	python3 "$project_root/tools/gxde/root-manifest.py" \
		--root "$root" --out-dir "$out_dir" --name gxde-rootfs \
		--meta "debian_suite=$debian_suite" \
		--meta "gxde_mirror=$gxde_mirror" \
		--meta "gxde_session=$(sed -n 's/^session=//p' "$root/etc/liuqin-gxde-session" 2>/dev/null || echo unknown)" \
		--meta "kernel_release=$(kernel_release)" \
		--meta "device_layer=$([ -f "$root/usr/share/liuqin/kernel.release" ] && echo yes || echo no)"
	# The boot contract consumes the same walk under its own name.
	cp "$out_dir/gxde-rootfs.hashes" "$out_dir/native-root.hashes"
}

stage_pack() {
	unmount_root
	command -v zstd >/dev/null || die 'zstd is required to pack the rootfs'
	rm -rf "$root/var/cache/apt/archives"/*.deb "$root/var/cache/apt/archives"/partial
	rm -rf "$root/var/lib/apt/lists"/*
	say 'packing rootfs.tar.zst'
	rm -f "$out_dir/rootfs.tar.zst" "$out_dir/rootfs.tar.zst.sha256"
	(
		cd "$root"
		find . -mindepth 1 -maxdepth 1 \
			! -name proc ! -name sys ! -name dev ! -name run -printf '%P\n' |
			LC_ALL=C sort | while IFS= read -r top; do printf '%s\0' "./$top"; done |
			tar --null --files-from=- --numeric-owner --owner=0 --group=0 \
				--mtime="@$source_date_epoch" -cf -
	) | zstd -T0 -3 -q -o "$out_dir/rootfs.tar.zst" ||
		die 'packing failed'
	sha256sum "$out_dir/rootfs.tar.zst" >"$out_dir/rootfs.tar.zst.sha256"
	cat "$out_dir/rootfs.tar.zst.sha256"
	du -sh "$out_dir/rootfs.tar.zst"
}

stage_check() {
	need_root
	say 'checking the assembled root'
	in_root /usr/lib/systemd/systemd --version | head -1
	[ -x "$root/usr/sbin/gdm3" ] || die 'gdm3 is missing (the native profile requires it)'
	[ -x "$root/usr/bin/gnome-shell" ] || die 'gnome-shell is missing (the native profile requires it)'
	[ -e "$root/usr/share/xsessions/$(sed -n 's/^session=//p' "$root/etc/liuqin-gxde-session").desktop" ] ||
		[ -e "$root/usr/share/wayland-sessions/$(sed -n 's/^session=//p' "$root/etc/liuqin-gxde-session").desktop" ] ||
		die 'the selected GXDE session has no desktop file'
	grep -q '^AutomaticLogin=' "$root/etc/gdm3/custom.conf" || die 'gdm autologin was not configured'
	[ -L "$root/etc/systemd/system/display-manager.service" ] || die 'display-manager.service is not a symlink'
	[ -f "$root/etc/liuqin-gxde-root" ] || die 'the GXDE marker is missing'
	[ "$(sha "$root/etc/liuqin-native-root")" = \
		4fdae4f7a27af8b0d4a2bbc168c7f01c3c5c6b5e245fcc521389d662f8212c5b ] ||
		die 'the native-root marker does not match the initramfs pin'
	[ -x "$root/usr/local/sbin/liuqin-gxde-firstboot" ] || die 'the firstboot helper is missing'
	say "root size: $(du -sh "$root" | cut -f1); session: $(sed -n 's/^session=//p' "$root/etc/liuqin-gxde-session")"
}

case ${1:-all} in
bootstrap) stage_bootstrap ;;
desktop) stage_desktop ;;
device) stage_device ;;
assemble) stage_assemble ;;
manifest) stage_manifest ;;
pack) stage_pack ;;
check) stage_check ;;
all)
	stage_bootstrap
	stage_desktop
	stage_device
	stage_assemble
	stage_manifest
	stage_pack
	stage_check
	;;
*)
	die 'usage: build-gxde-rootfs.sh [bootstrap|desktop|device|assemble|manifest|pack|check|all]'
	;;
esac
