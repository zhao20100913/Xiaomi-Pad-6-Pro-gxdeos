#!/bin/sh
# SPDX-License-Identifier: MIT
# Assemble a flashable GXDE bundle on a hosted CI runner.
#
# Everything except the exact-ROM sensor stack and the four stock WLAN blobs is
# rebuilt from this repository and public sources, so the job needs nothing but
# the fastboot ROM archive and a kernel build:
#
#   stock     super.img -> vendor/etc/sensors + vendor/firmware_mnt/image/qca6490
#   pool      FIRMWARE_POOL rebuilt from device/firmware (the tracked tree)
#   wlan      pinned ath11k-bdencoder -> WLAN_HSP2_TUPLE
#   topology  AudioReach @ pinned commit -> liuqin speaker topology
#   sensors   SSC userspace in the arm64 chroot (exact-ROM configs)
#   modules   normalized kernel module tree (modules.tar)
#   debs      liuqin-* device packages
#   device    install the packages, assemble the boot contract, write manifests
#   boot      boot.img and installer.img
#   bundle    rootfs.tar.gz + bundle.json + SHA256SUMS + installer self-check
#
# Stage selection: $1 (or all).  Every stage is idempotent except boot/bundle,
# which refuse to overwrite their own outputs.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
stage=${1:-all}
[ $# -eq 0 ] || shift
out_dir=${OUT_DIR:-"$project_root/out/gxde-image"}
case $out_dir in "$project_root"/out/*) ;; *) printf 'error: OUT_DIR must be below %s/out: %s\n' "$project_root" "$out_dir" >&2; exit 1 ;; esac
mkdir -p "$out_dir"
out_dir=$(CDPATH= cd -- "$out_dir" && pwd)
root=${GXDE_ROOT:-"$out_dir/root"}
kernel_source=${KERNEL_SOURCE:-"$project_root/../linux-sm8450-liuqin"}
kernel_out=${KERNEL_OUT:-"$project_root/out/kernel"}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
mkbootimg_dir=${MKBOOTIMG_DIR:-"$project_root/tools/local/aosp-mkbootimg"}
busybox=${BUSYBOX:-"$project_root/tools/local/busybox-arm64/usr/bin/busybox"}
device_deps=${LIUQIN_DEVICE_SUPPORT_DEPS:-'libasound2t64 (>= 1.2), python3-gi, python3-pyudev, init-system-helpers, libglib2.0-bin'}
audio_commit=2af1f1ebb8d4fd03b5f53891467ddde2e208a8a0
stock_inputs=${LIUQIN_IMAGE_INPUTS:-}

say() { printf '\n== %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "this stage needs root (chroot/overlay)"; }

mkdir -p "$out_dir"

stage_stock() {
	say 'extracting the stock device inputs'
	if [ -n "${SUPER_IMAGE:-}" ]; then
		python3 "$project_root/tools/gxde/prepare-stock-inputs.py" prepare \
			--super "$SUPER_IMAGE" --out "$out_dir/stock"
	elif [ -n "${ROM:-}" ]; then
		python3 "$project_root/tools/gxde/prepare-stock-inputs.py" prepare \
			"$ROM" --out "$out_dir/stock"
	else
		die 'set SUPER_IMAGE or ROM'
	fi
}

stage_pool() {
	say 'rebuilding the firmware pool from device/firmware'
	OUT_DIR="$out_dir" FORCE=1 FIRMWARE_TREE="${FIRMWARE_TREE:-$project_root/device/firmware/usr/lib/firmware}" \
		sh "$project_root/tools/gxde/prepare-firmware-pool.sh" >/dev/null
}

stage_wlan() {
	say 'assembling the WLAN firmware tuple'
	# device/firmware already ships the processed WCN6855 set that the stock
	# vendor blobs are normally turned into, so the tuple is rebuilt from it.
	src=$project_root/device/firmware/usr/lib/firmware/updates/ath11k/WCN6855/hw2.0
	tuple=$out_dir/wlan
	[ -f "$src/amss.bin" ] || die "tracked WLAN firmware is missing: $src"
	rm -rf "$tuple"
	mkdir -p "$tuple/hw2.0" "$tuple/hw2.1"
	for name in amss.bin m3.bin board-2.bin regdb.bin; do
		install -m 0644 "$src/$name" "$tuple/hw2.0/$name"
		ln -sf ../hw2.0/"$name" "$tuple/hw2.1/$name"
	done
	say "WLAN tuple: $tuple"
}

stage_topology() {
	say 'building the AudioReach speaker topology'
	src=${AUDIOREACH_TOPOLOGY_DIR:-"$project_root/tools/local/audioreach-topology"}
	if [ ! -d "$src/.git" ]; then
		rm -rf "$src"
		git clone --quiet --filter=blob:none https://github.com/linux-msm/audioreach-topology "$src" ||
			die 'cannot clone audioreach-topology'
	fi
	git -C "$src" fetch --quiet origin "$audio_commit" 2>/dev/null || true
	git -C "$src" checkout --quiet "$audio_commit" ||
		die "cannot check out audioreach-topology $audio_commit"
	mkdir -p "$out_dir/topology"
	AUDIOREACH_TOPOLOGY_DIR="$src" OUTPUT="$out_dir/topology/liuqin-tplg.bin" \
		sh "$project_root/tools/build-liuqin-audio-topology.sh"
}

stage_sensors() {
	if [ -f "$out_dir/sensors/artifacts/sensor-stack.tar" ]; then
		say "reusing the sensor stack: $out_dir/sensors"
		return
	fi
	say 'building the SSC userspace (arm64 chroot)'
	need_root
	[ -f "$out_dir/stock/rom-sensors/etc/sensors/sns_reg_config" ] ||
		die 'run the stock stage first'
	# The root archive deliberately omits the virtual filesystems, and the
	# sensor builder bind-mounts into them.
	mkdir -p "$root/proc" "$root/sys" "$root/dev/pts" "$root/run/systemd/resolve" "$root/tmp"
	chmod 1777 "$root/tmp"
	# The packed root carries no /dev, so the chroot tests that allocate a PTY
	# (umockdev) need the usual device symlinks before devpts is mounted.
	[ -e "$root/dev/ptmx" ] || ln -sfn pts/ptmx "$root/dev/ptmx"
	[ -e "$root/dev/fd" ] || ln -sfn /proc/self/fd "$root/dev/fd"
	[ -e "$root/dev/stdin" ] || ln -sfn /proc/self/fd/0 "$root/dev/stdin"
	[ -e "$root/dev/stdout" ] || ln -sfn /proc/self/fd/1 "$root/dev/stdout"
	[ -e "$root/dev/stderr" ] || ln -sfn /proc/self/fd/2 "$root/dev/stderr"
	[ -e "$root/dev/core" ] || ln -sfn /proc/kcore "$root/dev/core"
	ROOTFS="$root" \
	ROM_SENSORS="$out_dir/stock/rom-sensors/etc/sensors" \
	OUT_DIR="$out_dir/sensors" \
	UPDATE_APT=1 JOBS="$jobs" \
		sh "$project_root/tools/build-liuqin-sensors-stack.sh"
}

stage_modules() {
	say 'normalizing the kernel module tree'
	[ -d "$kernel_out/modules" ] || die "no kernel modules in $kernel_out/modules"
	KERNEL_DIR="$kernel_source" \
	KERNEL_OUT="$kernel_out" \
	KERNEL_COMMIT=$(python3 -c "import json,sys;print(json.load(open('$project_root/kernel/source.json'))['commit'])") \
	OUT_DIR="$out_dir/modules" \
		sh "$project_root/tools/build-liuqin-kernel-modules.sh"
}

stage_tools() {
	say 'fetching the pinned helper binaries'
	[ -x "$busybox" ] || sh "$project_root/tools/fetch-busybox-arm64.sh" >/dev/null
	[ -f "$mkbootimg_dir/mkbootimg.py" ] || sh "$project_root/tools/fetch-aosp-mkbootimg.sh" >/dev/null
}

stage_debs() {
	say 'building the liuqin device packages'
	need_root
	sensor_tar=$out_dir/sensors/artifacts/sensor-stack.tar
	[ -f "$sensor_tar" ] || die 'run the sensors stage first'
	OUT_DIR="$out_dir/debs" \
	UBUNTU_DESKTOP_ROOT="$root" \
	KERNEL_MODULES_DIR="$out_dir/modules" \
	KERNEL_IMAGE="$kernel_out/arch/arm64/boot/Image" \
	KERNEL_DTB="$kernel_out/arch/arm64/boot/dts/qcom/sm8475-xiaomi-liuqin.dtb" \
	FIRMWARE_TREE="${FIRMWARE_TREE:-$project_root/device/firmware}" \
	SENSOR_STACK_TAR="$sensor_tar" \
	SENSOR_STACK_SHA256=$(sha256sum "$sensor_tar" | cut -d' ' -f1) \
	POWER_SETTINGS_BINARY= \
	LIUQIN_DEVICE_SUPPORT_DEPS="$device_deps" \
	BUSYBOX="$busybox" \
		sh "$project_root/tools/build-liuqin-debs.sh" all
}

stage_device() {
	say 'installing the device layer and writing the boot contract'
	need_root
	# build-gxde-rootfs.sh consumes one stage per call.
	for step in device assemble manifest; do
		OUT_DIR="$out_dir" GXDE_ROOT="$root" GXDE_ALLOW_FOREIGN_ROOT=1 \
		DEVICE_DEBS_DIR="$out_dir/debs" KERNEL_MODULES_DIR="$kernel_out/modules" \
			sh "$project_root/tools/gxde/build-gxde-rootfs.sh" "$step" || exit 1
	done
	# The boot contract pins /usr/share/liuqin/kernel.release to the kernel that
	# produced the modules, so refuse a device layer built against another one.
	have=$(cat "$root/usr/share/liuqin/kernel.release")
	want=$(cat "$kernel_out/include/config/kernel.release")
	[ "$have" = "$want" ] ||
		die "device layer kernel release $have does not match the kernel build $want"
}

stage_boot() {
	say 'building boot.img and installer.img'
	need_root
	case $out_dir in "$project_root"/out/*) ;; *) die 'boot output must live below out/' ;; esac
	[ -f "$out_dir/native-root.hashes" ] || die 'run the device stage first'
	[ -f "$out_dir/topology/liuqin-tplg.bin" ] || die 'run the topology stage first'
	mkdir -p "$out_dir/stock/empty-overlay" "$out_dir/stock/empty-base"
	# build-installer-runtime.py refuses to write into an existing directory.
	rm -rf "$out_dir/installer-runtime"
	python3 "$project_root/tools/lib/build-installer-runtime.py" \
		--root "$root" --out "$out_dir/installer-runtime"
	rm -rf "$out_dir/boot" "$out_dir/installer"
	OUT_DIR="$out_dir/boot" \
	NATIVE_ROOT_HASHES="$out_dir/native-root.hashes" \
	AUDIO_TOPOLOGY="$out_dir/topology/liuqin-tplg.bin" \
	FIRMWARE_POOL="$out_dir/firmware-pool" \
	WLAN_HSP2_TUPLE="$out_dir/wlan" \
	STOCK_OVERLAY_DIR="$out_dir/stock/empty-overlay" \
	STOCK_BASE_DIR="$out_dir/stock/empty-base" \
	MKBOOTIMG_DIR="$mkbootimg_dir" \
	KERNEL_SOURCE="$kernel_source" KERNEL_OUT="$kernel_out" \
		sh "$project_root/tools/build-liuqin-native-boot.sh"
	OUT_DIR="$out_dir/installer" \
	INSTALLER_RUNTIME="$out_dir/installer-runtime" \
	NATIVE_ROOT_HASHES="$out_dir/native-root.hashes" \
	AUDIO_TOPOLOGY="$out_dir/topology/liuqin-tplg.bin" \
	FIRMWARE_POOL="$out_dir/firmware-pool" \
	WLAN_HSP2_TUPLE="$out_dir/wlan" \
	STOCK_OVERLAY_DIR="$out_dir/stock/empty-overlay" \
	STOCK_BASE_DIR="$out_dir/stock/empty-base" \
	MKBOOTIMG_DIR="$mkbootimg_dir" \
	KERNEL_SOURCE="$kernel_source" KERNEL_OUT="$kernel_out" \
		sh "$project_root/tools/build-liuqin-native-boot.sh"
}

stage_bundle() {
	say 'packing the bundle'
	need_root
	boot_img=$out_dir/boot/boot-liuqin-native.img
	installer_img=$out_dir/installer/boot-liuqin-native.img
	[ -f "$boot_img" ] && [ -f "$installer_img" ] || die 'run the boot stage first'
	archive=$out_dir/rootfs.tar.gz
	rm -f "$archive"
	(
		cd "$root"
		find . -mindepth 1 -maxdepth 1 \
			! -name proc ! -name sys ! -name dev ! -name run -printf '%P\n' |
			LC_ALL=C sort | while IFS= read -r top; do printf '%s\0' "./$top"; done |
			tar --null --files-from=- --numeric-owner --owner=0 --group=0 \
				--mtime="@${SOURCE_DATE_EPOCH:-$(git -C "$project_root" log -1 --format=%ct)}" \
				-cf - |
			gzip -1 -n
	) >"$archive" || die 'rootfs packing failed'
	[ -s "$archive" ] || die 'rootfs.tar.gz is empty'

	bundle=$out_dir/bundle
	rm -rf "$bundle"
	mkdir -p "$bundle"
	cp "$boot_img" "$bundle/boot.img"
	cp "$installer_img" "$bundle/installer.img"
	cp "$archive" "$bundle/rootfs.tar.gz"
	cp "$project_root/tools/install-liuqin.py" "$bundle/install.py"
	cp "$project_root/tools/lib/liuqin_layout.py" "$bundle/liuqin_layout.py"
	cp "$project_root/tools/lib/liuqin-rom-images.json" "$bundle/liuqin-rom-images.json"
	for doc in INSTALL-TESTING.en.md INSTALL-TESTING.md FINGERPRINT.en.md FINGERPRINT.md; do
		[ -f "$project_root/docs/$doc" ] && cp "$project_root/docs/$doc" "$bundle/$doc"
	done
	cp "$project_root/NOTICE" "$bundle/NOTICE"
	cp "$project_root/LICENSE" "$bundle/LICENSE"

	kernel_commit=$(git -C "$kernel_source" rev-parse HEAD)
	release=$(cat "$kernel_out/include/config/kernel.release")
	python3 - "$bundle" "$project_root" "$kernel_commit" "$release" "$out_dir" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path

bundle, project = Path(sys.argv[1]), Path(sys.argv[2])
commit, release, work = sys.argv[3], sys.argv[4], Path(sys.argv[5])


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


files = {path.name: sha(path) for path in sorted(bundle.iterdir())
         if path.name not in ('bundle.json', 'SHA256SUMS')}
session = 'unknown'
session_file = work / 'inputs' / 'gxde-session'
if session_file.exists():
    session = session_file.read_text().strip()
metadata = {
    'device': 'liuqin',
    'status': 'OFFLINE_ASSEMBLED',
    'version': (project / 'VERSION').read_text().strip(),
    'distro': 'gxde',
    'gxde_base': 'debian-trixie',
    'gxde_session': session,
    'kernel_commit': commit,
    'project_commit': subprocess.check_output(['git', '-C', str(project), 'rev-parse', 'HEAD'], text=True).strip(),
    'project_dirty': bool(subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'])),
    'kernel_release': release,
    'features': {'displayport': True, 'gxde_desktop': True, 'display_manager': 'gdm3'},
    'files': files,
}
(bundle / 'bundle.json').write_text(json.dumps(metadata, indent=2) + '\n')
files['bundle.json'] = sha(bundle / 'bundle.json')
(bundle / 'SHA256SUMS').write_text(''.join(f'{d}  {n}\n' for n, d in files.items()))
print('bundle files: ' + ', '.join(sorted(files)))
PY

	# The bundle is assembled offline, so it is not DEVICE_TESTED yet; --check
	# still verifies every file against bundle.json, which --allow-unverified keeps.
	say 'the bundle is offline-assembled: its checksums are verified, the tablet is not'
	python3 "$project_root/tools/install-liuqin.py" --bundle "$bundle" --check --allow-unverified ||
		die 'the installer self-check rejected the bundle'
	say "bundle ready: $bundle"
}

run_stage() {
	case $1 in
	stock) stage_stock ;;
	pool) stage_pool ;;
	wlan) stage_wlan ;;
	topology) stage_topology ;;
	sensors) stage_sensors ;;
	modules) stage_modules ;;
	tools) stage_tools ;;
	debs) stage_debs ;;
	device) stage_device ;;
	boot) stage_boot ;;
	bundle) stage_bundle ;;
	*) die "unknown stage: $1" ;;
	esac
}

case $stage in
all)
	stage_tools; stage_stock; stage_pool; stage_wlan; stage_topology
	stage_sensors; stage_modules; stage_debs; stage_device; stage_boot; stage_bundle
	;;
*)
	run_stage "$stage"
	for more in "$@"; do run_stage "$more"; done
	;;
esac
