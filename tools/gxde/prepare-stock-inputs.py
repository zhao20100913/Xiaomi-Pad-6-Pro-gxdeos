#!/usr/bin/env python3
"""Turn the stock liuqin fastboot ROM into the inputs the image pipeline wants.

The GXDE image is assembled from two halves: a public, reproducible desktop
root (tools/gxde/build-gxde-rootfs.sh) and a device layer that needs a handful
of files which only exist in Xiaomi's firmware.  This tool extracts exactly
those files from the stock ROM and lays them out the way
tools/build-liuqin-firmware-prep.sh, tools/build-liuqin-wlan.py and
tools/build-liuqin-sensors-stack.sh expect to find them.

Subcommands
    probe        report the logical-partition metadata of a super image
    unpack       extract named logical partitions from a super image
    fs-tree      list or extract paths from an extracted filesystem image
    prepare      do all of the above for a ROM archive and write inputs/

Nothing here needs root, mount(2) or any third-party Python package.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import zlib

GEOM_OFFSET = 4096
GEOM_MAGIC = 0x616C4467
HEADER_MAGIC = 0x414C5030
SECTOR = 512

EXTENT_LINEAR = 0
EXTENT_ZERO = 2

# Partitions that carry the files the device layer needs.  A/B super images
# suffix them with _a; plain fastboot images do not.
VENDOR_NAMES = ("vendor", "vendor_a")


def say(message: str) -> None:
    print(f"prepare-stock-inputs: {message}", flush=True)


def die(message: str) -> "NoReturn":  # noqa: F821 - typing is not worth an import
    print(f"prepare-stock-inputs: {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Logical-partition metadata (liblp format, see AOSP metadata_format.h)
# --------------------------------------------------------------------------


def parse_geometry(data: bytes) -> dict:
    """Parse and verify the 4096-byte geometry block at offset 4096."""
    block = data[GEOM_OFFSET:GEOM_OFFSET + 4096]
    if len(block) < 4096:
        die("image is too small to hold logical-partition geometry")
    magic, struct_size = struct.unpack_from("<II", block, 0)
    if magic != GEOM_MAGIC:
        die(f"no logical-partition geometry (magic 0x{magic:08x})")
    checksum = block[8:40]
    metadata_max_size, slot_count, logical_block_size = struct.unpack_from("<III", block, 40)
    zeroed = bytearray(block)
    zeroed[8:40] = b"\0" * 32
    verified = hashlib.sha256(bytes(zeroed)).digest() == checksum
    return {
        "struct_size": struct_size,
        "metadata_max_size": metadata_max_size,
        "slot_count": slot_count,
        "logical_block_size": logical_block_size,
        "checksum_verified": verified,
    }


def parse_header(data: bytes, offset: int) -> dict:
    """Parse the metadata header.

    Two layouts are in the wild.  AOSP liblp stores a CRC32 header/tables pair
    and puts the four table descriptors at +24.  Xiaomi's super images use the
    same header magic but store SHA-256 digests (32 bytes each) and move the
    descriptors to +80; the tables themselves are identical.
    """
    magic, major, minor, header_size = struct.unpack_from("<IHHI", data, offset)
    if magic != HEADER_MAGIC:
        die(f"metadata header magic mismatch at {offset}: 0x{magic:08x}")

    def descriptors(base: int) -> dict:
        out = {}
        for name, index in (("partitions", 0), ("extents", 1), ("groups", 2), ("block_devices", 3)):
            out[name] = struct.unpack_from("<III", data, offset + base + index * 12)
        return out

    def plausible(table: dict) -> bool:
        if table["partitions"][2] not in (48, 52):
            return False
        if table["extents"][2] not in (24, 32):
            return False
        if table["groups"][2] not in (48, 52):
            return False
        if table["block_devices"][2] not in (60, 64):
            return False
        return all(0 < count <= 8192 for _base, count, _size in table.values())

    aosp = descriptors(24)
    modern = descriptors(80)
    if header_size >= 128 and plausible(modern):
        layout = "metadata-sha256"
        table = modern
        tables_size = struct.unpack_from("<I", data, offset + 44)[0]
        zeroed = bytearray(data[offset:offset + header_size])
        zeroed[12:44] = b"\0" * 32
        header_ok = hashlib.sha256(bytes(zeroed)).digest() == data[offset + 12:offset + 44]
        tables = data[offset + header_size:offset + header_size + tables_size]
        tables_ok = hashlib.sha256(tables).digest() == data[offset + 48:offset + 80]
    elif plausible(aosp):
        layout = "metadata-crc32"
        table = aosp
        header_checksum = struct.unpack_from("<I", data, offset + 12)[0]
        tables_size = struct.unpack_from("<I", data, offset + 16)[0]
        tables_checksum = struct.unpack_from("<I", data, offset + 20)[0]
        zeroed = bytearray(data[offset:offset + header_size])
        zeroed[12:16] = b"\0" * 4
        header_ok = zlib.crc32(bytes(zeroed)) & 0xFFFFFFFF == header_checksum
        tables = data[offset + header_size:offset + header_size + tables_size]
        tables_ok = zlib.crc32(tables) & 0xFFFFFFFF == tables_checksum
    else:
        die("unrecognised logical-partition metadata layout")

    return {
        "version": f"{major}.{minor}",
        "layout": layout,
        "header_size": header_size,
        "tables_size": tables_size,
        "header_checksum_verified": header_ok,
        "tables_checksum_verified": tables_ok,
        "descriptors": table,
    }


def parse_tables(data: bytes, offset: int, header: dict) -> dict:
    desc = header["descriptors"]

    def entries(name: str) -> list[tuple[int, int]]:
        table_offset, count, size = desc[name]
        base = offset + header["header_size"] + table_offset
        return [(base + i * size, size) for i in range(count)]

    partitions = []
    for base, size in entries("partitions"):
        name = data[base:base + 36].split(b"\0", 1)[0].decode("utf-8", "replace")
        attributes, first_extent, num_extents, group_index = struct.unpack_from("<IIII", data, base + 36)
        partitions.append(
            {
                "name": name,
                "attributes": attributes,
                "first_extent_index": first_extent,
                "num_extents": num_extents,
                "group_index": group_index,
            }
        )

    extents = []
    for base, size in entries("extents"):
        num_sectors = struct.unpack_from("<Q", data, base)[0]
        target_type = struct.unpack_from("<I", data, base + 8)[0]
        if size >= 32:
            # Natural alignment: target_data is 8-byte aligned after target_type.
            target_data = struct.unpack_from("<Q", data, base + 16)[0]
            target_source = struct.unpack_from("<I", data, base + 24)[0]
        else:
            target_data = struct.unpack_from("<Q", data, base + 12)[0]
            target_source = struct.unpack_from("<I", data, base + 20)[0]
        extents.append(
            {
                "num_sectors": num_sectors,
                "target_type": target_type,
                "target_data": target_data,
                "target_source": target_source,
            }
        )

    groups = []
    for base, _size in entries("groups"):
        name = data[base:base + 36].split(b"\0", 1)[0].decode("utf-8", "replace")
        flags = struct.unpack_from("<I", data, base + 36)[0]
        maximum_size = struct.unpack_from("<Q", data, base + 40)[0]
        groups.append({"name": name, "flags": flags, "maximum_size": maximum_size})

    block_devices = []
    for base, entry_size in entries("block_devices"):
        first_logical_sector, alignment, alignment_offset = struct.unpack_from("<III", data, base)
        # liblp writes a 64-byte entry (size at 16, name at 24); a few tools
        # emit the packed 60-byte form instead.
        if entry_size >= 64:
            size = struct.unpack_from("<Q", data, base + 16)[0]
            name = data[base + 24:base + 60].split(b"\0", 1)[0].decode("utf-8", "replace")
            flags = struct.unpack_from("<I", data, base + 60)[0]
        else:
            size = struct.unpack_from("<Q", data, base + 12)[0]
            name = data[base + 20:base + 56].split(b"\0", 1)[0].decode("utf-8", "replace")
            flags = struct.unpack_from("<I", data, base + 56)[0]
        block_devices.append(
            {
                "first_logical_sector": first_logical_sector,
                "alignment": alignment,
                "alignment_offset": alignment_offset,
                "size": size,
                "partition_name": name,
                "flags": flags,
            }
        )

    return {"partitions": partitions, "extents": extents, "groups": groups, "block_devices": block_devices}


def partition_size(partition: dict, extents: list[dict]) -> int:
    first = partition["first_extent_index"]
    return sum(e["num_sectors"] for e in extents[first:first + partition["num_extents"]]) * SECTOR


def metadata_layout(data: bytes) -> dict:
    geometry = parse_geometry(data)
    # [4096] primary geometry, [8192] backup geometry, [12288] metadata header.
    offset = GEOM_OFFSET + 2 * 4096
    header = parse_header(data, offset)
    tables = parse_tables(data, offset, header)
    return {"geometry": geometry, "header": header, "tables": tables, "metadata_offset": offset}


def load_image(path: str, limit: int | None = None) -> bytes:
    with open(path, "rb") as handle:
        return handle.read() if limit is None else handle.read(limit)


def probe(path: str) -> dict:
    data = load_image(path)
    if data[0] == 0xED and len(data) > 4 and struct.unpack_from("<I", data)[0] == 0xED26FF3A:
        die("this is a sparse image; run simg2img first")
    layout = metadata_layout(data)
    rows = []
    for partition in layout["tables"]["partitions"]:
        rows.append(
            {
                "name": partition["name"],
                "size": partition_size(partition, layout["tables"]["extents"]),
                "extents": partition["num_extents"],
                "group": partition["group_index"],
            }
        )
    return {
        "geometry": layout["geometry"],
        "header": {k: v for k, v in layout["header"].items() if k != "descriptors"},
        "partitions": rows,
        "block_devices": layout["tables"]["block_devices"],
    }


# --------------------------------------------------------------------------
# Images
# --------------------------------------------------------------------------


SPARSE_MAGIC = 0xED26FF3A


def is_sparse(path: str) -> bool:
    with open(path, "rb") as handle:
        head = handle.read(4)
    return len(head) == 4 and struct.unpack("<I", head)[0] == SPARSE_MAGIC


def unsparse(path: str, out: str) -> str:
    """Expand an Android sparse image without any external tool."""
    with open(path, "rb") as src, open(out, "wb") as dst:
        header = src.read(28)
        if len(header) < 28:
            die("sparse header is truncated")
        magic, major, _minor, file_hdr_size, _chunk_hdr, block_size, total_blocks, total_chunks, _checksum = struct.unpack(
            "<IHHHHIIII", header
        )
        if magic != SPARSE_MAGIC:
            die("not a sparse image")
        if major != 1:
            die(f"unsupported sparse major version {major}")
        src.seek(file_hdr_size)
        written = 0
        for _ in range(total_chunks):
            chunk = src.read(12)
            if len(chunk) < 12:
                die("sparse image ended inside a chunk header")
            chunk_type, _reserved, chunk_blocks, total_size = struct.unpack("<HHII", chunk)
            payload = total_size - 12
            if chunk_type == 0xCAC1:  # raw
                remaining = chunk_blocks * block_size
                while remaining:
                    block = src.read(min(remaining, 1 << 20))
                    if not block:
                        die("sparse image ended inside a raw chunk")
                    dst.write(block)
                    remaining -= len(block)
                    written += len(block)
            elif chunk_type == 0xCAC2:  # fill
                if payload != 4:
                    die("sparse fill chunk has an unexpected size")
                fill = src.read(4)
                remaining = chunk_blocks * block_size
                while remaining:
                    piece = min(remaining, 1 << 20)
                    dst.write(fill * (piece // 4))
                    remaining -= piece
                    written += piece
            elif chunk_type == 0xCAC3:  # don't care
                remaining = chunk_blocks * block_size
                zero = b"\0" * (1 << 20)
                while remaining:
                    piece = min(remaining, 1 << 20)
                    dst.write(zero[:piece])
                    remaining -= piece
                    written += piece
            elif chunk_type == 0xCAC4:  # crc32
                src.read(payload)
            else:
                die(f"unknown sparse chunk type 0x{chunk_type:04x}")
        expected = total_blocks * block_size
        if written != expected:
            die(f"sparse expansion wrote {written} bytes, expected {expected}")
    return out


def extract_partition(super_path: str, layout: dict, partition: dict, out_path: str) -> None:
    extents = layout["tables"]["extents"]
    first = partition["first_extent_index"]
    with open(super_path, "rb") as src, open(out_path, "wb") as dst:
        for extent in extents[first:first + partition["num_extents"]]:
            length = extent["num_sectors"] * SECTOR
            if extent["target_type"] == EXTENT_ZERO:
                dst.write(b"\0" * length)
                continue
            if extent["target_type"] != EXTENT_LINEAR:
                die(f"partition {partition['name']} uses unsupported extent type {extent['target_type']}")
            src.seek(extent["target_data"] * SECTOR)
            remaining = length
            while remaining:
                block = src.read(min(remaining, 1 << 20))
                if not block:
                    die(f"super image ended inside partition {partition['name']}")
                dst.write(block)
                remaining -= len(block)


# --------------------------------------------------------------------------
# Filesystems inside the extracted images
# --------------------------------------------------------------------------


def fs_kind(path: str) -> str:
    with open(path, "rb") as handle:
        handle.seek(0x438)
        magic = handle.read(2)
        if magic == b"\x53\xef":
            return "ext4"
        handle.seek(1024)
        if handle.read(4) == b"\xe2\xe1\xf5\xe0":
            return "erofs"
        handle.seek(0)
        if handle.read(2) == b"\x55\xaa" or handle.read(8)[3:11] == b"FAT":
            return "vfat"
    return "unknown"


def require(tool: str) -> str:
    found = shutil.which(tool)
    if not found:
        die(f"{tool} is required but not installed")
    return found


def fs_list(image: str, path: str) -> list[str]:
    kind = fs_kind(image)
    if kind == "ext4":
        out = subprocess.run(
            [require("debugfs"), "-R", f"ls -l {path}", image],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        ).stdout
        return [line for line in out.splitlines() if line and not line.startswith("debugfs")]
    if kind == "erofs":
        out = subprocess.run(
            [require("fsck.erofs"), "--ls", f"--path={path}", image],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        ).stdout
        return [line for line in out.splitlines() if line.strip()]
    die(f"cannot list {path}: unsupported filesystem {kind}")


def fs_type(image: str, path: str) -> str:
    kind = fs_kind(image)
    if kind == "ext4":
        out = subprocess.run(
            [require("debugfs"), "-R", f"stat {path}", image],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        ).stdout
        for line in out.splitlines():
            if line.strip().startswith("Type:"):
                return line.split(":", 1)[1].strip()
        die(f"cannot stat {path} in {image}: {out.strip()}")
    if kind == "erofs":
        listing = fs_list(image, path)
        if listing and any("d" == line.split()[0][:1] for line in listing if line.strip()):
            return "directory"
        return "regular"
    die(f"cannot stat {path}: unsupported filesystem {kind}")


def fs_extract_all(image: str, out_dir: str) -> None:
    """Unpack a whole partition; the erofs tools in Ubuntu 24.04 predate
    `--extract=image:path`, so a single path cannot be pulled out."""
    kind = fs_kind(image)
    os.makedirs(out_dir, exist_ok=True)
    if kind == "ext4":
        subprocess.run([require("debugfs"), "-R", f"rdump / {out_dir}", image], check=True)
    elif kind == "erofs":
        subprocess.run([require("fsck.erofs"), f"--extract={out_dir}", image], check=True)
    else:
        die(f"cannot extract {image}: unsupported filesystem {kind}")


def fs_dump(image: str, path: str, out_dir: str) -> None:
    """Copy one path (file or directory tree) out of the image."""
    kind = fs_kind(image)
    os.makedirs(out_dir, exist_ok=True)
    if kind == "ext4":
        if fs_type(image, path) == "directory":
            subprocess.run([require("debugfs"), "-R", f"rdump {path} {out_dir}", image], check=True)
        else:
            subprocess.run(
                [require("debugfs"), "-R", f"dump {path} {os.path.join(out_dir, os.path.basename(path))}", image],
                check=True,
            )
        return
    if kind == "erofs":
        if fs_type(image, path) == "directory":
            subprocess.run([require("fsck.erofs"), f"--extract={image}:{out_dir}", f"--path={path}"], check=True)
        else:
            subprocess.run(
                [require("fsck.erofs"), f"--extract={image}:{os.path.join(out_dir, os.path.basename(path))}", path],
                check=True,
            )
        return
    die(f"cannot extract {path}: unsupported filesystem {kind}")


# --------------------------------------------------------------------------
# ROM archive
# --------------------------------------------------------------------------


def rom_members(path: str) -> list[tarfile.TarInfo]:
    with tarfile.open(path, "r:gz") as archive:
        return [member for member in archive.getmembers() if member.isfile()]


def rom_extract(path: str, wanted: list[str], out_dir: str) -> dict[str, str]:
    """Extract archive members whose basename matches one of `wanted`."""
    os.makedirs(out_dir, exist_ok=True)
    found: dict[str, str] = {}
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            base = os.path.basename(member.name)
            if base not in wanted or base in found:
                continue
            target = os.path.join(out_dir, base)
            say(f"extracting {member.name} ({member.size} bytes)")
            source = archive.extractfile(member)
            assert source is not None
            with open(target, "wb") as handle:
                shutil.copyfileobj(source, handle, 1 << 20)
            found[base] = target
    return found


def unpack_rom(rom: str, work: str) -> dict[str, str]:
    members = rom_members(rom)
    say(f"ROM holds {len(members)} files")
    names = {os.path.basename(m.name): m for m in members}
    for member in members:
        say(f"  {member.name}  {member.size}")
    images = os.path.join(work, "rom")
    found = rom_extract(
        rom,
        ["super.img", "NON-HLOS.bin", "BTFM.bin", "vendor_boot.img", "dtbo.img"],
        images,
    )
    return found


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------



# --------------------------------------------------------------------------
# Stock device-tree blobs
# --------------------------------------------------------------------------
#
# The bootloader applies its own DTBO entries to whatever DTB we ship, and it
# picks them by id/rev, so the boot image has to export every symbol those
# overlays can fix up.  Two stock inputs describe that set: the 44 entries of
# dtbo.img, and the 14 base DTBs carried in vendor_boot.img.
#
# build-bootimg.sh expects them as `entry.<N>` and `dtb-<NN>.dtb` files.

DTBO_MAGIC = 0xD7B7AB1E
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


def dtbo_header(data: bytes, label: str) -> tuple[str, int, int, int, int]:
    """Return (struct order, header_size, entry_size, count, entries_offset).

    AOSP writes the dtbo header little-endian, but images produced by Qualcomm
    tooling store every field big-endian -- including the magic, whose bytes are
    the literal d7 b7 ab 1e. Pick whichever order yields a plausible table.
    """
    for order in ("<", ">"):
        fields = struct.unpack_from(order + "6I", data, 0)
        if fields[0] != DTBO_MAGIC:
            continue
        _total, header_size, entry_size, count, entries_offset = fields[1:]
        if 0 < count <= 512 and 8 <= entry_size <= 512 and header_size >= 32:
            return order, header_size, entry_size, count, entries_offset
    die(f"{label}: not a dtbo image (magic 0x{data[:4].hex()})")


def dtbo_entries(path: str) -> list[bytes]:
    data = open(path, "rb").read()
    if len(data) < 32:
        die(f"{path}: too small for a dtbo image")
    order, _header_size, entry_size, count, entries_offset = dtbo_header(data, path)
    entries = []
    for index in range(count):
        offset_field = entries_offset + index * entry_size
        if offset_field + 8 > len(data):
            die(f"{path}: dtbo entry {index} header is past the end of the image")
        size, offset = struct.unpack_from(order + "II", data, offset_field)
        if offset + size > len(data):
            die(f"{path}: dtbo entry {index} runs past the end of the image")
        entries.append(data[offset : offset + size])
    return entries


def dtbo_entries_bytes(data: bytes) -> list[bytes]:
    order, _header_size, entry_size, count, entries_offset = dtbo_header(data, "dtbo table")
    entries = []
    for index in range(count):
        offset_field = entries_offset + index * entry_size
        size, offset = struct.unpack_from(order + "II", data, offset_field)
        entries.append(data[offset : offset + size])
    return entries


def vendor_boot_dtb_section(path: str) -> bytes:
    data = open(path, "rb").read()
    if data[:8] != b"VNDRBOOT":
        die(f"{path}: not a vendor_boot image")
    version, page_size = struct.unpack_from("<II", data, 8)
    ramdisk_size = struct.unpack_from("<I", data, 24)[0]
    header_size = struct.unpack_from("<I", data, 2096)[0]
    dtb_size = struct.unpack_from("<I", data, 2100)[0]
    if version not in (3, 4):
        say(f"{path}: vendor_boot header version {version}; reading the v3 layout")
    if not 1024 <= header_size <= 8192 or page_size == 0:
        die(f"{path}: implausible vendor_boot header (header_size {header_size}, page_size {page_size})")
    start = page_size + (ramdisk_size + page_size - 1) // page_size * page_size
    if start + dtb_size > len(data):
        die(f"{path}: vendor_boot dtb section is past the end of the image")
    return data[start : start + dtb_size]


def extract_stock_dtb(dtbo_path: str, vendor_boot_path: str, out_dir: str) -> dict[str, int]:
    entries = dtbo_entries(dtbo_path)
    dtbs = fdt_blobs(vendor_boot_dtb_section(vendor_boot_path))
    overlay_dir = os.path.join(out_dir, "dtbo")
    base_dir = os.path.join(out_dir, "dtbs")
    shutil.rmtree(overlay_dir, ignore_errors=True)
    shutil.rmtree(base_dir, ignore_errors=True)
    os.makedirs(overlay_dir)
    os.makedirs(base_dir)
    for index, entry in enumerate(entries):
        with open(os.path.join(overlay_dir, f"entry.{index}"), "wb") as handle:
            handle.write(entry)
    for index, blob in enumerate(dtbs):
        with open(os.path.join(base_dir, f"dtb-{index:02d}.dtb"), "wb") as handle:
            handle.write(blob)
    say(f"stock DTBO entries: {len(entries)} -> {overlay_dir}")
    say(f"stock base DTBs: {len(dtbs)} -> {base_dir}")
    if len(entries) != 44:
        die(f"{dtbo_path}: expected 44 DTBO entries, found {len(entries)}")
    if len(dtbs) != 14:
        die(f"{vendor_boot_path}: expected 14 base DTBs, found {len(dtbs)}")
    return {"dtbo_entries": len(entries), "base_dtbs": len(dtbs)}


def cmd_dtb(args: argparse.Namespace) -> int:
    if args.rom:
        work = os.path.join(os.path.abspath(args.out), "work")
        found = rom_extract(args.rom, ["dtbo.img", "vendor_boot.img"], os.path.join(work, "rom"))
    else:
        found = {"dtbo.img": args.dtbo, "vendor_boot.img": args.vendor_boot}
    if not found.get("dtbo.img") or not found.get("vendor_boot.img"):
        die("need both dtbo.img and vendor_boot.img (from --rom or the two paths)")
    counts = extract_stock_dtb(found["dtbo.img"], found["vendor_boot.img"], os.path.abspath(args.out))
    print(json.dumps(counts, indent=2))
    return 0


def cmd_probe(args: argparse.Namespace) -> int:
    report = probe(args.image)
    print(json.dumps(report, indent=2))
    return 0


def cmd_unpack(args: argparse.Namespace) -> int:
    layout = metadata_layout(load_image(args.image, limit=1 << 22))
    os.makedirs(args.out, exist_ok=True)
    wanted = args.partitions or [p["name"] for p in layout["tables"]["partitions"]]
    by_name = {p["name"]: p for p in layout["tables"]["partitions"]}
    extracted = 0
    for name in wanted:
        if name not in by_name:
            say(f"skipping missing partition {name}")
            continue
        extracted += 1
        target = os.path.join(args.out, f"{name}.img")
        extract_partition(args.image, layout, by_name[name], target)
        say(f"{name}: {os.path.getsize(target)} bytes -> {target}")
    if extracted == 0:
        die(f"none of the requested partitions exist (have {', '.join(by_name)})")
    return 0


def cmd_fstree(args: argparse.Namespace) -> int:
    if args.extract:
        for path in args.paths:
            fs_dump(args.image, path, args.out)
            say(f"extracted {path} -> {args.out}")
        return 0
    for path in args.paths or ["/"]:
        say(f"{path}:")
        for line in fs_list(args.image, path):
            say(f"  {line}")
    return 0


SENSOR_CONFIG_COUNT = 56
SENSOR_CONFIG_MANIFEST_SHA256 = "1cbf79b3ba5bfdd3efa152bcb5900ff6addd703f61b19def59cea62ae3c56867"
SNS_REG_CONFIG_SHA256 = "d89a5dfd69b9681f6864bca8d24c17fb922cb19a9ed3a0f7f5c00e4b5dc1089b"
WLAN_INPUTS = {
    "amss20.bin": "cc3e477fa698a28bdb8c8115a071893f9b2f5230de190ad525e74fd69bbb6092",
    "m3.bin": "6938b4bba268a02659ee5e16992971aa0e2fab103a4f60cbccf65e4bd8ac9836",
    "regdb.bin": "06810e85c94c8f412c4e72cb38546cac90db7fdbadd45aae00f977f862d38a7b",
    "bd_m81gf.elf": "aa8ae92d781e09db8cffa960b00c9606e4bb65d9c7a89f9b32df1bd24aee8573",
}


def aosp_unpack_bootimg() -> str:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    script = os.path.join(root, "local", "aosp-mkbootimg", "unpack_bootimg.py")
    if not os.path.exists(script):
        die(f"{script} is missing; run tools/fetch-aosp-mkbootimg.sh first")
    return script


def vendor_ramdisks(boot_image: str, out_dir: str) -> list[str]:
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run(
        [sys.executable, aosp_unpack_bootimg(), "--boot_img", boot_image, "--out", out_dir],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return [
        os.path.join(out_dir, name)
        for name in sorted(os.listdir(out_dir))
        if name.startswith("vendor_ramdisk")
    ]


def cpio_files(blob: bytes) -> dict[str, bytes]:
    if blob[:2] == b"\x1f\x8b":
        blob = gzip.decompress(blob)
    files: dict[str, bytes] = {}
    pos = 0
    while pos + 110 <= len(blob):
        header = blob[pos : pos + 110]
        if header[:6] not in (b"070701", b"070702"):
            break
        try:
            fields = [int(header[6 + 8 * i : 14 + 8 * i], 16) for i in range(13)]
        except ValueError:
            break
        size, namesize = fields[6], fields[11]
        name_start = pos + 110
        name = blob[name_start : name_start + namesize - 1].decode("utf-8", "replace")
        data_start = name_start + namesize
        data_start += (-data_start) % 4
        if name == "TRAILER!!!":
            break
        if size and not name.endswith("/"):
            files[name.lstrip("./")] = blob[data_start : data_start + size]
        pos = data_start + size
        pos += (-pos) % 4
    return files


def find_dir(root: str, predicate) -> str | None:
    for base, dirs, files in os.walk(root):
        if predicate(base, dirs, files):
            return base
    return None


def find_file(root: str, name: str) -> str | None:
    for base, _dirs, files in os.walk(root):
        if name in files:
            return os.path.join(base, name)
    return None


def sensor_dir_expectations(path: str) -> None:
    config = os.path.join(path, "config")
    names = sorted(n for n in os.listdir(config) if os.path.isfile(os.path.join(config, n)))
    if len(names) != SENSOR_CONFIG_COUNT:
        die(f"{config}: expected {SENSOR_CONFIG_COUNT} configs, found {len(names)}")
    lines = []
    for name in names:
        digest = hashlib.sha256(open(os.path.join(config, name), "rb").read()).hexdigest()
        lines.append(f"{digest}  {name}\n")
    seen = hashlib.sha256("".join(lines).encode()).hexdigest()
    if seen != SENSOR_CONFIG_MANIFEST_SHA256:
        die(f"{config}: sensor config manifest is {seen}, expected {SENSOR_CONFIG_MANIFEST_SHA256}")
    registry = os.path.join(path, "sns_reg_config")
    if hashlib.sha256(open(registry, "rb").read()).hexdigest() != SNS_REG_CONFIG_SHA256:
        die(f"{registry}: sensor registry does not match the pinned ROM")


def wlan_dir_expectations(path: str) -> None:
    for name, digest in WLAN_INPUTS.items():
        candidate = os.path.join(path, name)
        if not os.path.isfile(candidate):
            die(f"{path}: missing stock WLAN input {name}")
        if hashlib.sha256(open(candidate, "rb").read()).hexdigest() != digest:
            die(f"{candidate}: stock WLAN input does not match the pinned ROM")


def cmd_prepare(args: argparse.Namespace) -> int:
    out = os.path.abspath(args.out)
    work = os.path.join(out, "work")
    os.makedirs(work, exist_ok=True)

    if args.super:
        super_image = os.path.abspath(args.super)
        say(f"using the extracted super image {super_image}")
    else:
        say("reading the ROM archive")
        found = unpack_rom(args.rom, work)
        super_image = found.get("super.img")
        if not super_image:
            die("the ROM archive has no super.img")
    if is_sparse(super_image):
        say("expanding the sparse super image")
        raw = os.path.join(work, "super.raw")
        unsparse(super_image, raw)
        super_image = raw

    say("reading the logical partitions")
    layout = metadata_layout(load_image(super_image, limit=1 << 22))
    names = [p["name"] for p in layout["tables"]["partitions"]]
    for slot in ("vendor_a", "vendor"):
        if slot in names:
            vendor_name = slot
            break
    else:
        die(f"no vendor partition in the super image (have {', '.join(names)})")
    vendor_image = os.path.join(work, f"{vendor_name}.img")
    extract_partition(super_image, layout, next(p for p in layout["tables"]["partitions"] if p["name"] == vendor_name), vendor_image)
    say(f"{vendor_name}: {os.path.getsize(vendor_image)} bytes")

    say("unpacking the vendor filesystem")
    vendor_tree = os.path.join(work, "vendor-tree")
    fs_extract_all(vendor_image, vendor_tree)

    say("extracting the exact-ROM sensor stack")
    sensors = find_dir(vendor_tree, lambda base, dirs, files: "config" in dirs and "sns_reg_config" in files)
    if not sensors:
        die("vendor/etc/sensors/config was not found in the vendor partition")
    sensor_dir_expectations(sensors)
    dest = os.path.join(out, "rom-sensors", "etc", "sensors")
    shutil.copytree(sensors, dest, dirs_exist_ok=True)
    say(f"sensor stack: {dest}")

    say("extracting the stock WLAN blobs")
    # The stock names (amss20.bin, m3.bin, regdb.bin, bd_m81gf.elf) do not
    # survive into the vendor image under a predictable path.  They are also
    # no longer required: device/firmware ships the processed WCN6855 set that
    # tools/gxde/build-gxde-image.sh turns into the HSP2 tuple.  Try anyway,
    # and carry on when they are absent.
    wanted = dict(WLAN_INPUTS)
    located: dict[str, str] = {}

    def scan_tree(root: str) -> None:
        for base, _dirs, files in os.walk(root):
            for name in files:
                path = os.path.join(base, name)
                try:
                    if os.path.getsize(path) > 64 << 20:
                        continue
                    with open(path, "rb") as handle:
                        digest = hashlib.sha256(handle.read()).hexdigest()
                except OSError:
                    continue
                if digest in wanted and wanted[digest] not in located:
                    located[wanted[digest]] = path

    scan_tree(vendor_tree)
    boot_image = os.path.join(work, "rom", "vendor_boot.img")
    if len(located) < len(WLAN_INPUTS) and os.path.exists(boot_image):
        ramdisk_dir = os.path.join(work, "ramdisk-files")
        os.makedirs(ramdisk_dir, exist_ok=True)
        for part in vendor_ramdisks(boot_image, os.path.join(work, "vendor-boot")):
            try:
                entries = cpio_files(open(part, "rb").read())
            except Exception as error:  # noqa: BLE001 - diagnostics only
                say(f"  {os.path.basename(part)}: {error}")
                continue
            for name, data in entries.items():
                digest = hashlib.sha256(data).hexdigest()
                if digest not in wanted:
                    continue
                target = os.path.join(ramdisk_dir, wanted[digest])
                with open(target, "wb") as handle:
                    handle.write(data)
                located.setdefault(wanted[digest], target)

    wlan_dest = os.path.join(out, "wlan-vendor")
    if len(located) == len(WLAN_INPUTS):
        os.makedirs(wlan_dest, exist_ok=True)
        for name, path in located.items():
            shutil.copyfile(path, os.path.join(wlan_dest, name))
            say(f"  {name} <- {path}")
        wlan_dir_expectations(wlan_dest)
        say(f"WLAN inputs: {wlan_dest}")
    else:
        missing = [name for name in WLAN_INPUTS if name not in located]
        say(f"stock WLAN blobs absent ({', '.join(missing)}); using the tracked set")

    say("extracting the stock DTBO entries and vendor_boot DTBs")
    rom_dir = os.path.join(work, "rom")
    dtbo_image = os.path.join(rom_dir, "dtbo.img")
    if not os.path.exists(dtbo_image) and args.rom:
        rom_extract(args.rom, ["dtbo.img"], rom_dir)
    boot_image = os.path.join(rom_dir, "vendor_boot.img")
    if not os.path.exists(dtbo_image) or not os.path.exists(boot_image):
        die("the ROM archive has no dtbo.img or vendor_boot.img; the boot image needs both")
    stock_dtb_dir = os.path.join(out, "stock-dtb")
    dtb_counts = extract_stock_dtb(dtbo_image, boot_image, stock_dtb_dir)

    inputs = {
        "rom": os.path.abspath(args.rom),
        "stock_dtb": stock_dtb_dir,
        "dtbo_entries": dtb_counts["dtbo_entries"],
        "base_dtbs": dtb_counts["base_dtbs"],
        "vendor_partition": vendor_name,
        "sensor_root": dest,
        "wlan_vendor": wlan_dest if len(located) == len(WLAN_INPUTS) else None,
    }
    with open(os.path.join(out, "inputs.json"), "w") as handle:
        json.dump(inputs, handle, indent=2)
        handle.write("\n")
    print(json.dumps(inputs, indent=2))
    return 0


def cmd_locate(args: argparse.Namespace) -> int:
    """Search raw files for directory-entry names (diagnostic helper)."""
    needles = [name.encode() for name in args.names]
    for image in args.images:
        if not os.path.exists(image):
            say(f"{image}: missing")
            continue
        hits: list[str] = []
        with open(image, "rb") as handle:
            chunk = handle.read(8 << 20)
            base = 0
            while chunk:
                for needle in needles:
                    start = 0
                    while True:
                        found = chunk.find(needle, start)
                        if found < 0:
                            break
                        hits.append(f"{image}:{base + found}:{needle.decode()}")
                        if len(hits) >= 20:
                            break
                        start = found + 1
                base += len(chunk)
                chunk = handle.read(8 << 20)
        say(f"{image}: {len(hits)} hit(s)")
        for hit in hits[:20]:
            say(f"  {hit}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("dtb", help="extract the stock DTBO entries and vendor_boot base DTBs")
    p.add_argument("--rom", help="the fastboot ROM archive to read both images from")
    p.add_argument("--dtbo", help="an already extracted dtbo.img")
    p.add_argument("--vendor-boot", help="an already extracted vendor_boot.img")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_dtb)

    p = sub.add_parser("locate", help="search images for directory-entry names")
    p.add_argument("images", nargs="+")
    p.add_argument("--names", nargs="+", required=True)
    p.set_defaults(func=cmd_locate)

    p = sub.add_parser("probe", help="report logical partitions of a super image")
    p.add_argument("image")
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("unpack", help="extract logical partitions")
    p.add_argument("image")
    p.add_argument("out")
    p.add_argument("partitions", nargs="*")
    p.set_defaults(func=cmd_unpack)

    p = sub.add_parser("fs-tree", help="list or extract paths from a filesystem image")
    p.add_argument("image")
    p.add_argument("paths", nargs="*")
    p.add_argument("--extract", action="store_true")
    p.add_argument("--out", default=".")
    p.set_defaults(func=cmd_fstree)

    p = sub.add_parser("unsparse", help="expand an Android sparse image")
    p.add_argument("image")
    p.add_argument("out")
    p.set_defaults(func=lambda a: (say(unsparse(a.image, a.out)), 0)[1])

    p = sub.add_parser("rom", help="list and extract the ROM archive")
    p.add_argument("rom")
    p.add_argument("--out", required=True)
    p.set_defaults(func=lambda a: print(json.dumps(unpack_rom(a.rom, a.out), indent=2)) and 0)

    p = sub.add_parser("prepare", help="extract the stock device inputs from a ROM archive")
    p.add_argument("rom", nargs="?")
    p.add_argument("--super", help="use an already extracted super image instead of the archive")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_prepare)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
