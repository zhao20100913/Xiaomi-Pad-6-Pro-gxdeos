#!/bin/sh
# SPDX-License-Identifier: MIT
# Resolve the pinned ath11k-bdencoder from qca/qca-swiss-army-knife.
#
# tools/build-liuqin-wlan.py verifies the encoder by sha256, but the file is not
# distributed in a release, so the exact revision has to be recovered from the
# repository history (the blob itself is stable; only the branch tip moves).
set -eu

out=${OUT:-$(pwd)/bdencoder/ath11k-bdencoder}
want=${BDENCODER_SHA256:-4a2181d16d6ff35d60773b75aaa1bbe349afea7f03d4d2d97a596b81636a9e87}
repo=${BDENCODER_REPO:-https://github.com/qca/qca-swiss-army-knife}
path=${BDENCODER_PATH:-tools/scripts/ath11k/ath11k-bdencoder}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '== %s\n' "$*" >&2; }

command -v git >/dev/null || die "git is required"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

say "cloning $repo (blobless)"
git clone --quiet --filter=blob:none --no-checkout "$repo" "$work/qsak" ||
	die "cannot clone $repo"
cd "$work/qsak"

# Newest first: the pinned revision is normally close to the tip.
for commit in $(git log --all --format=%H -- "$path"); do
	git cat-file -e "$commit:$path" 2>/dev/null || continue
	git show "$commit:$path" >"$work/candidate" 2>/dev/null || continue
	seen=$(sha256sum "$work/candidate" | cut -d' ' -f1)
	if [ "$seen" = "$want" ]; then
		mkdir -p "$(dirname -- "$out")"
		install -m 0755 "$work/candidate" "$out"
		printf '%s\n' "$commit" >"$out.commit"
		say "resolved bdencoder $commit"
		printf '%s\n' "$out"
		exit 0
	fi
done

die "no revision of $path matches $want"
