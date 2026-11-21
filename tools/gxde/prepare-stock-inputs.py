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
    magic, major, minor, header_size, checksum, tables_size, tables_checksum = struct.unpack_from(
        "<IHHIIII", data, offset
    )
    if magic != HEADER_MAGIC:
        die(f"metadata header magic mismatch at {offset}: 0x{magic:08x}")
    zeroed = bytearray(data[offset:offset + header_size])
    zeroed[12:16] = b"\0" * 4
    verified = zlib.crc32(bytes(zeroed)) & 0xFFFFFFFF == checksum
    tables = data[offset + header_size:offset + header_size + tables_size]
    tables_verified = zlib.crc32(tables) & 0xFFFFFFFF == tables_checksum
    descriptors = {}
    for name, index in (("partitions", 0), ("extents", 1), ("groups", 2), ("block_devices", 3)):
        base = offset + 24 + index * 12
        descriptors[name] = struct.unpack_from("<III", data, base)
    return {
        "version": f"{major}.{minor}",
        "header_size": header_size,
        "tables_size": tables_size,
        "header_checksum_verified": verified,
        "tables_checksum_verified": tables_verified,
        "descriptors": descriptors,
    }


def parse_tables(data: bytes, offset: int, header: dict) -> dict:
    desc = header["descriptors"]

    def entries(name: str) -> list[tuple[int, int]]:
        table_offset, count, size = desc[name]
        base = offset + table_offset
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
    offset = GEOM_OFFSET + 4096
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
    found = rom_extract(rom, ["super.img", "NON-HLOS.bin", "BTFM.bin"], images)
    return found


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


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


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

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

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
