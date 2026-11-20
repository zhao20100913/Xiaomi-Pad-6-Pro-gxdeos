#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Emit the manifests the liuqin boot contract consumes for a GXDE root.

Three files are written from one walk of the tree:

  <name>.manifest   the upstream native-root format, one row per regular file:
                    "<sha256>  f <mode> <uid>:<gid> ./path"
  <name>.hashes     "<sha256>  /abs/path", the device-layer manifest that
                    tools/lib/build-root-contract.py hashes into the contract
  <name>.identity   key=value summary (entry count, per-file digests, metadata)

The walk skips the volatile filesystems and caches that a packed image must not
carry.  Regular files only: symlinks, devices and directories are recorded by
the archive itself, not by the file manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path

SKIP_TOP = {
    'dev', 'proc', 'run', 'sys', 'tmp',
    'var/cache', 'var/log', 'var/tmp', 'var/lib/apt/lists',
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def walked(root: Path):
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root).as_posix()
        if any(rel == s or rel.startswith(s + '/') for s in SKIP_TOP):
            continue
        if path.is_symlink() or not path.is_file():
            continue
        yield rel, path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--out-dir', type=Path, required=True)
    parser.add_argument('--name', default='gxde-rootfs')
    parser.add_argument('--meta', action='append', default=[],
                        help='extra identity key=value pairs')
    parser.add_argument('--min-entries', type=int, default=1000)
    args = parser.parse_args()

    root = args.root.resolve()
    if not (root / 'usr/lib/systemd/systemd').exists():
        raise SystemExit(f'not a root filesystem: {root}')
    out = args.out_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)

    manifest = out / (args.name + '.manifest')
    hashes = out / (args.name + '.hashes')
    identity = out / (args.name + '.identity')

    entries = 0
    with manifest.open('w', encoding='utf-8') as mf, hashes.open('w', encoding='utf-8') as hf:
        for rel, path in walked(root):
            st = path.stat()
            h = digest(path)
            mf.write(f'{h}  f {st.st_mode & 0o7777:04o} {st.st_uid}:{st.st_gid} ./{rel}\n')
            hf.write(f'{h}  /{rel}\n')
            entries += 1
    if entries < args.min_entries:
        raise SystemExit(f'manifest is implausibly small: {entries} entries')

    def file_sha(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    lines = [
        f'{args.name}_version=v1',
        'debian_suite=trixie',
        f'entries={entries}',
        f'manifest_sha256={file_sha(manifest)}',
        f'hashes_sha256={file_sha(hashes)}',
    ]
    for item in args.meta:
        key, sep, value = item.partition('=')
        if not sep or not key or not value:
            raise SystemExit(f'--meta wants key=value, got {item!r}')
        lines.append(f'{key}={value}')
    identity.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print('\n'.join(lines))
    return 0


if __name__ == '__main__':
    sys.exit(main())
