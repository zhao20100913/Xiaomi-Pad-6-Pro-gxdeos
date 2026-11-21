#!/bin/sh
# SPDX-License-Identifier: MIT
# Rebuild the FIRMWARE_POOL expected by tools/build-liuqin-firmware-prep.sh from
# the firmware tree that this repository already tracks (device/firmware).
#
# The tracked tree is the *output* of the firmware builder, so every pinned
# input can be re-derived from it: the stock handset never has to be touched.
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out_dir=${OUT_DIR:?set OUT_DIR to the output directory (pool goes to $OUT_DIR/firmware-pool)}
fw_tree=${FIRMWARE_TREE:-$project_root/device/firmware/usr/lib/firmware}
pool=$out_dir/firmware-pool
manifest=$project_root/device/firmware/firmware.manifest

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*" >&2; }

[ -d "$fw_tree" ] || die "firmware tree is unavailable: $fw_tree"
[ -f "$manifest" ] || die "firmware manifest is unavailable: $manifest"
manifest_sha=$(sha256sum "$manifest" | cut -d' ' -f1)
[ "$manifest_sha" = 012c413e0a5d5c3c14631fbdfe50da5c51e95ffc1ae431b8d93f776538b65ba2 ] ||
	die "tracked firmware tree is not the pinned one (manifest $manifest_sha)"

if [ -e "$pool" ]; then
	[ "${FORCE:-0}" = 1 ] || die "pool already exists: $pool (set FORCE=1 to rebuild)"
	rm -rf -- "$pool"
fi

# check_tree <source> <relative path below the firmware tree>
check_tree() {
	[ -f "$1" ] || die "missing firmware: $1"
	want=$(grep -F "  /usr/lib/firmware/$2" "$manifest" | cut -d' ' -f1 | head -n 1)
	[ -n "$want" ] || die "firmware is not listed in the manifest: $2"
	seen=$(sha256sum "$1" | cut -d' ' -f1)
	[ "$want" = "$seen" ] || die "firmware hash mismatch: $2"
}

copy() { # copy <source> <destination> <relative path below the firmware tree>
	check_tree "$1" "$3"
	install -D -m 0644 "$1" "$2"
}

say "touch firmware"
mkdir -p "$pool/touch-nt36532/vendor/firmware"
for name in novatek_nt36532_m81_fw_csot.bin novatek_nt36532_m81_fw_tm.bin; do
	copy "$fw_tree/novatek/liuqin/$name" "$pool/touch-nt36532/vendor/firmware/$name" "novatek/liuqin/$name"
done

say "Bluetooth firmware"
mkdir -p "$pool/bt-qca6490/vendor/bt_firmware/image"
bt_pattern='^(hpbtfw2[01]\.tlv|hpnv2[01]g?\.(bin|b[0-9a-f]+))$'
bt_count=0
for src in "$fw_tree"/qca/*; do
	[ -f "$src" ] || continue
	name=$(basename -- "$src")
	printf '%s\n' "$name" | grep -Eq "$bt_pattern" || continue
	copy "$src" "$pool/bt-qca6490/vendor/bt_firmware/image/$name" "qca/$name"
	bt_count=$((bt_count + 1))
done
[ "$bt_count" -ge 40 ] || die "expected the whole btqca name set, found only $bt_count files"

say "WLAN firmware"
board=$fw_tree/ath11k/WCN6855/hw2.0/board.bin
copy "$board" "$pool/wlan-qca6490/vendor/firmware_mnt/image/qca6490/bd_m81.elf" "ath11k/WCN6855/hw2.0/board.bin"
[ "$(dd if="$board" bs=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] ||
	die "WLAN board data is not an ELF image: $board"
for name in amss.bin.zst board-2.bin.zst m3.bin.zst regdb.bin.zst; do
	copy "$fw_tree/ath11k/WCN6855/hw2.0/$name" "$pool/wlan-qca6490/upstream/WCN6855/hw2.0/$name" "ath11k/WCN6855/hw2.0/$name"
done

say "regulatory database"
mkdir -p "$pool/regulatory/upstream"
for name in regulatory.db regulatory.db.p7s; do
	copy "$fw_tree/$name" "$pool/regulatory/upstream/$name" "$name"
done

say "GPU firmware"
mkdir -p "$pool/gpu-adreno730/vendor"
copy "$fw_tree/qcom/sm8475/liuqin/a730_zap.mbn" "$pool/gpu-adreno730/vendor/a730_zap.mbn" "qcom/sm8475/liuqin/a730_zap.mbn"
copy "$fw_tree/updates/qcom/a730_sqe.fw" "$pool/gpu-adreno730/vendor/a730_sqe.fw" "updates/qcom/a730_sqe.fw"
copy "$fw_tree/updates/qcom/gmu_gen70000.bin" "$pool/gpu-adreno730/vendor/gmu_gen70000.bin" "updates/qcom/gmu_gen70000.bin"

say "DSP firmware"
mkdir -p "$pool/dsp-sm8475/vendor/qcom/sm8475/liuqin"
dsp_count=0
for src in "$fw_tree"/qcom/sm8475/liuqin/*; do
	[ -f "$src" ] || continue
	name=$(basename -- "$src")
	[ "$name" = a730_zap.mbn ] && continue
	copy "$src" "$pool/dsp-sm8475/vendor/qcom/sm8475/liuqin/$name" "qcom/sm8475/liuqin/$name"
	dsp_count=$((dsp_count + 1))
done
[ "$dsp_count" = 68 ] || die "DSP firmware count is $dsp_count, expected 68"

say "pool ready: $pool"
printf '%s\n' "$pool"
