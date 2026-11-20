#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Assemble a flashable GXDE OS bundle for the Xiaomi Pad 6 Pro from
#   - a GXDE root built by tools/gxde/build-gxde-rootfs.sh, and
#   - the project's prepared stock inputs (LIUQIN_IMAGE_INPUTS), the same
#     directory of extracted stock firmware/DTBO/vendor_boot material that
#     tools/build-liuqin-image.py requires.
#
# This replaces the Ubuntu-specific stages of tools/build-liuqin-image.py
# (copy/install/assemble/manifest look for an Ubuntu root and a distro manifest
# with an Ubuntu hash) while reusing every distro-neutral piece: the module
# tree builder, the device .deb builder, the contract generator, the initramfs
# and boot-image builders, and the installer runtime builder.
#
# It must run as root on the machine that owns the stock inputs (they are not
# redistributable), with the root from build-gxde-rootfs.sh already carrying
# the device layer (or with DEVICE_DEBS_DIR set so this script can install it).
#
# Output: $OUT/bundle/{boot.img,installer.img,rootfs.tar.gz,bundle.json,...}
# plus out/native-root.hashes and out/native-root.contract for inspection.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=${OUT_DIR:-"$project_root/out/gxde-image"}
root=${GXDE_ROOT:?"set GXDE_ROOT to the GXDE root built by build-gxde-rootfs.sh"}
kernel_out=${KERNEL_OUT:?"set KERNEL_OUT to the locked kernel build output"}
kernel_source=${KERNEL_SOURCE:-"$project_root/../linux-sm8450-liuqin"}
inputs_file=${LIUQIN_IMAGE_INPUTS:?"set LIUQIN_IMAGE_INPUTS to the prepared-input JSON"}
mkbootimg_dir=${MKBOOTIMG_DIR:-"$project_root/tools/local/aosp-mkbootimg"}
device_debs_dir=${DEVICE_DEBS_DIR:-}
# The Ubuntu Settings rebuild is not shipped in a GXDE root; the plain schema
# is still compiled by the device-support package.
device_support_deps=${LIUQIN_DEVICE_SUPPORT_DEPS:-'libasound2t64 (>= 1.2), python3-gi, python3-pyudev, init-system-helpers, libglib2.0-bin'}

die() { printf 'gxde-image: %s\n' "$*" >&2; exit 1; }
say() { printf 'gxde-image: %s\n' "$*" >&2; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

[ "$(id -u)" = 0 ] || die 'assembly runs as root (it chroots into the assembled tree)'
case $out in
/*) ;;
*) die "OUT_DIR must be an absolute path (got $out)" ;;
esac
case $out in */../*|*/..|*/./*|*/.|*/) die 'output path must not contain traversal' ;; esac
for input in "$kernel_out/arch/arm64/boot/Image" "$kernel_out/.config" "$inputs_file" \
	"$root/usr/lib/systemd/systemd"; do
	[ -e "$input" ] || die "missing input: $input"
done

# ---------------------------------------------------------------------------
# prepared stock inputs
# ---------------------------------------------------------------------------
# The JSON is the project's own input contract; keep its key set authoritative
# and fail loudly instead of guessing at a partial directory.
mkdir -p "$out"
inputs_env=$out/prepared-inputs.env
python3 - "$inputs_file" >"$inputs_env" <<'PY' || die 'could not read the prepared inputs'
import json, shlex, sys
from pathlib import Path
required = {
    'FIRMWARE_POOL', 'FIRMWARE_TREE', 'FIRMWARE_MANIFEST_SHA256',
    'AUDIO_TOPOLOGY', 'WLAN_HSP2_TUPLE', 'STOCK_OVERLAY_DIR', 'STOCK_BASE_DIR',
    'SENSOR_STACK_TAR', 'SENSOR_STACK_SHA256', 'POWER_SETTINGS_BINARY',
    'POWER_SETTINGS_MANIFEST', 'BUSYBOX', 'MKBOOTIMG_DIR', 'FINGERPRINT_BUNDLE',
    'UBUNTU_DESKTOP_ROOT', 'DESKTOP_ROOTFS_MANIFEST',
}
data = json.loads(Path(sys.argv[1]).read_text())
missing = required - set(data)
if missing:
    raise SystemExit('inputs.json is missing: ' + ', '.join(sorted(missing)))
base = Path(sys.argv[1]).resolve().parent
for key, value in data.items():
    if key.endswith('_SHA256'):
        print(f'{key}={shlex.quote(value)}')
    else:
        print(f'{key}={shlex.quote(str((base / value).resolve()))}')
PY
. "$inputs_env"
# The JSON may carry its own mkbootimg checkout; keep the default otherwise.
mkbootimg_dir=${MKBOOTIMG_DIR:-$mkbootimg_dir}
[ -d "$mkbootimg_dir" ] || die "MKBOOTIMG_DIR is missing: $mkbootimg_dir"

for key in FIRMWARE_POOL AUDIO_TOPOLOGY WLAN_HSP2_TUPLE STOCK_OVERLAY_DIR STOCK_BASE_DIR SENSOR_STACK_TAR BUSYBOX; do
	eval "value=\${$key}"
	[ -e "$value" ] || die "prepared input $key is missing at $value"
done
if [ -n "$FINGERPRINT_BUNDLE" ] && [ ! -e "$FINGERPRINT_BUNDLE" ]; then
	say "WARNING: FINGERPRINT_BUNDLE is not present; shipping a root without the fingerprint provider"
	FINGERPRINT_BUNDLE=
fi

kernel_commit=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$project_root/kernel/source.json")
release=$(cat "$kernel_out/include/config/kernel.release")
say "kernel $release at $(printf '%s' "$kernel_commit" | cut -c1-12)"

mkdir -p "$out"
# A previous bundle is never reused: partial assembly is worse than none.
[ ! -e "$out/bundle" ] || die "output already exists: $out/bundle"

# ---------------------------------------------------------------------------
# module tree and device packages
# ---------------------------------------------------------------------------
say 'building the matching module tree'
OUT_DIR="$out/modules" KERNEL_DIR="$kernel_source" KERNEL_OUT="$kernel_out" \
	KERNEL_COMMIT="$kernel_commit" \
	sh "$project_root/tools/build-liuqin-kernel-modules.sh"

say 'building the liuqin device packages against the GXDE root'
OUT_DIR="$out/debs" UBUNTU_DESKTOP_ROOT="$root" KERNEL_MODULES_DIR="$out/modules" \
	POWER_SETTINGS_BINARY= LIUQIN_DEVICE_SUPPORT_DEPS="$device_support_deps" \
	FIRMWARE_TREE="$FIRMWARE_TREE" FIRMWARE_MANIFEST_SHA256="$FIRMWARE_MANIFEST_SHA256" \
	SENSOR_STACK_TAR="$SENSOR_STACK_TAR" SENSOR_STACK_SHA256="$SENSOR_STACK_SHA256" \
	BUSYBOX="$BUSYBOX" BUSYBOX_SHA256="${BUSYBOX_SHA256:-52151e7f322f926b64049cdaa1410dc3ea6485525e0624b05813791c219ae933}" \
	sh "$project_root/tools/build-liuqin-debs.sh" all

say 'installing the device layer into the GXDE root'
DEVICE_DEBS_DIR="$out/debs" OUT_DIR="$out" GXDE_ROOT="$root" GXDE_ALLOW_FOREIGN_ROOT=1 \
	sh "$project_root/tools/gxde/build-gxde-rootfs.sh" device
OUT_DIR="$out" GXDE_ROOT="$root" GXDE_ALLOW_FOREIGN_ROOT=1 \
	sh "$project_root/tools/gxde/build-gxde-rootfs.sh" assemble

installed=$(cat "$root/usr/share/liuqin/kernel.release")
[ "$installed" = "$release" ] ||
	die "root carries kernel $installed but the build produced $release"

say 'writing the native-root manifests'
OUT_DIR="$out" GXDE_ROOT="$root" GXDE_ALLOW_FOREIGN_ROOT=1 \
	sh "$project_root/tools/gxde/build-gxde-rootfs.sh" manifest
[ -f "$out/native-root.hashes" ] || die 'the native-root hashes were not written'

# ---------------------------------------------------------------------------
# boot, installer and rootfs payloads
# ---------------------------------------------------------------------------
say 'building boot.img'
OUT_DIR="$out/boot" NATIVE_ROOT_HASHES="$out/native-root.hashes" \
	AUDIO_TOPOLOGY="$AUDIO_TOPOLOGY" FIRMWARE_POOL="$FIRMWARE_POOL" \
	WLAN_HSP2_TUPLE="$WLAN_HSP2_TUPLE" STOCK_OVERLAY_DIR="$STOCK_OVERLAY_DIR" \
	STOCK_BASE_DIR="$STOCK_BASE_DIR" MKBOOTIMG_DIR="$mkbootimg_dir" \
	KERNEL_SOURCE="$kernel_source" KERNEL_OUT="$kernel_out" \
	sh "$project_root/tools/build-liuqin-native-boot.sh"

say 'building the installer runtime'
python3 "$project_root/tools/lib/build-installer-runtime.py" \
	--root "$root" --out "$out/installer-runtime"

say 'building installer.img'
OUT_DIR="$out/installer" INSTALLER_RUNTIME="$out/installer-runtime" \
	NATIVE_ROOT_HASHES="$out/native-root.hashes" \
	AUDIO_TOPOLOGY="$AUDIO_TOPOLOGY" FIRMWARE_POOL="$FIRMWARE_POOL" \
	WLAN_HSP2_TUPLE="$WLAN_HSP2_TUPLE" STOCK_OVERLAY_DIR="$STOCK_OVERLAY_DIR" \
	STOCK_BASE_DIR="$STOCK_BASE_DIR" MKBOOTIMG_DIR="$mkbootimg_dir" \
	KERNEL_SOURCE="$kernel_source" KERNEL_OUT="$kernel_out" \
	sh "$project_root/tools/build-liuqin-native-boot.sh"

say 'packing rootfs.tar.gz'
build_rootfs_archive() {
	(
		cd "$root"
		find . -mindepth 1 -maxdepth 1 \
			! -name proc ! -name sys ! -name dev ! -name run -printf '%P\n' |
			LC_ALL=C sort | while IFS= read -r top; do printf '%s\0' "./$top"; done |
			tar --null --files-from=- --numeric-owner --owner=0 --group=0 \
				--mtime="@${SOURCE_DATE_EPOCH:-$(git -C "$project_root" log -1 --format=%ct)}" \
				-cf - |
			gzip -1 -n
	) >"$out/rootfs.tar.gz" || die 'rootfs packing failed'
}
build_rootfs_archive
[ -s "$out/rootfs.tar.gz" ] || die 'rootfs.tar.gz is empty'

# ---------------------------------------------------------------------------
# bundle
# ---------------------------------------------------------------------------
say 'writing the bundle'
bundle=$out/bundle
mkdir -p "$bundle"
cp "$out/boot/boot-liuqin-native.img" "$bundle/boot.img"
cp "$out/installer/boot-liuqin-native.img" "$bundle/installer.img"
mv "$out/rootfs.tar.gz" "$bundle/rootfs.tar.gz"
cp "$project_root/tools/install-liuqin.py" "$bundle/install.py"
cp "$project_root/tools/lib/liuqin_layout.py" "$bundle/liuqin_layout.py"
cp "$project_root/tools/lib/liuqin-rom-images.json" "$bundle/liuqin-rom-images.json"
for doc in INSTALL-TESTING.en.md INSTALL-TESTING.md FINGERPRINT.en.md FINGERPRINT.md; do
	[ -f "$project_root/docs/$doc" ] && cp "$project_root/docs/$doc" "$bundle/$doc"
done
cp "$project_root/NOTICE" "$bundle/NOTICE"
cp "$project_root/LICENSE" "$bundle/LICENSE"
[ -z "$FINGERPRINT_BUNDLE" ] || cp "$FINGERPRINT_BUNDLE" "$bundle/fingerprint-build-inputs.tar.gz"

python3 - "$bundle" "$project_root" "$kernel_out" "$kernel_commit" "$release" "$out" <<'PY'
import hashlib, json, os, subprocess, sys
from pathlib import Path

bundle = Path(sys.argv[1])
project = Path(sys.argv[2])
commit, release = sys.argv[4], sys.argv[5]
work = Path(sys.argv[6])


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


files = {}
for path in sorted(bundle.iterdir()):
    if path.name in ('bundle.json', 'SHA256SUMS'):
        continue
    files[path.name] = sha(path)

session = 'unknown'
session_file = work / 'inputs' / 'gxde-session'
if session_file.exists():
    session = session_file.read_text().strip()

dirty = bool(subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain']))
metadata = {
    'device': 'liuqin',
    'status': 'OFFLINE_ASSEMBLED',
    'version': (project / 'VERSION').read_text().strip(),
    'distro': 'gxde',
    'gxde_base': 'debian-trixie',
    'gxde_session': session,
    'kernel_commit': commit,
    'project_commit': subprocess.check_output(
        ['git', '-C', str(project), 'rev-parse', 'HEAD'], text=True).strip(),
    'project_dirty': dirty,
    'kernel_release': release,
    'features': {
        'displayport': True,
        'gxde_desktop': True,
        'display_manager': 'gdm3',
        'native_fingerprint': 'fingerprint-build-inputs.tar.gz' in files,
    },
    'files': files,
}
(bundle / 'bundle.json').write_text(json.dumps(metadata, indent=2) + '\n')
files['bundle.json'] = sha(bundle / 'bundle.json')
(bundle / 'SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in files.items()))
print('bundle files: ' + ', '.join(sorted(files)))
PY

python3 "$project_root/tools/install-liuqin.py" --bundle "$bundle" --check ||
	die 'the installer self-check rejected the bundle'
say "bundle ready: $bundle"
say 'flashing needs --allow-unverified on install-liuqin.py: this bundle was assembled offline, not device-tested'
