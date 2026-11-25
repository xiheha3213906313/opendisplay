#!/bin/bash
set -euo pipefail

if [[ $# != 2 || ! -d "$1" || "$1" != *.app || "$2" != *.dmg ]]; then
    echo "Usage: $0 path/to/App.app output.dmg" >&2
    exit 2
fi

dir="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
volume="$(basename "$app" .app)"
mkdir -p "$(dirname "$2")"
output="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

xcrun swift -module-cache-path "$stage/modules" "$dir/background.swift" "$stage/background.png"
"${DMGBUILD:-dmgbuild}" -s "$dir/layout.py" \
    -D "app=$app" -D "background=$stage/background.png" "$volume" "$stage/install.dmg"
mv -f "$stage/install.dmg" "$output"
