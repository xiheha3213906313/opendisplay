#!/bin/bash
set -euo pipefail

tag="${1:?Pass the release tag}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
scripts="$(cd "$(dirname "$0")" && pwd)"
repo=xiheha3213906313/opendisplay
if [[ "$(gh api "repos/$repo/releases/latest" --jq .tag_name)" != "$tag" ]]; then
    echo "Keeping the current Mac downloads. $tag is not the latest stable release."
    exit 0
fi

git fetch --no-tags origin "refs/tags/$tag"
if ! git cat-file -e FETCH_HEAD:Mac/MainBranchUpdates.swift 2>/dev/null; then
    echo "Keeping the current Mac downloads. $tag predates downloads from main."
    exit 0
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
gh release download "$tag" --repo "$repo" --pattern OpenDisplay.dmg \
    --pattern OpenDisplayReceiver.dmg --dir "$stage/assets"
bash "$scripts/prepare-mac-downloads.sh" "${tag#v}" "$stage/assets" "$stage/downloads"

git fetch --no-tags origin refs/heads/main
git switch --detach FETCH_HEAD
destination=downloads/macos
if [[ -f "$destination/latest.json" ]] && ! python3 - "$stage/downloads/latest.json" "$destination/latest.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as proposed, open(sys.argv[2]) as published:
    next_release, current_release = (json.load(file) for file in (proposed, published))
    next_version, current_version = (tuple(map(int, release['version'].split('.')))
                                     for release in (next_release, current_release))
    builds = ('senderBuild', 'receiverBuild')
    blocked = next_version < current_version or (next_version == current_version and
              any(next_release[product] < current_release[product] for product in builds))
    sys.exit(1 if blocked else 0)
PY
then
    echo "Keeping the current Mac downloads. main already has a newer build."
    exit 0
fi

mkdir -p "$destination"
cp "$stage/downloads/"* "$destination/"
git add -- "$destination/OpenDisplay.dmg" "$destination/OpenDisplayReceiver.dmg" "$destination/latest.json"
if git diff --cached --quiet; then exit 0; fi
git -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Publish Mac downloads for $tag"
git push origin HEAD:refs/heads/main
