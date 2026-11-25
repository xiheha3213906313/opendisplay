#!/bin/bash
set -euo pipefail

destination="${1:?Pass a destination for Sparkle 2.10.1}"
if [[ -x "$destination/bin/generate_appcast" && -f "$destination/Sparkle.framework/Sparkle" ]]; then
    exit 0
fi
mkdir -p "$destination"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
curl --fail --silent --show-error --location --retry 3 \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz \
    -o "$stage/Sparkle.tar.xz"
(
    cd "$stage"
    printf '%s\n' '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  Sparkle.tar.xz' |
        shasum -a 256 -c
)
tar -xf "$stage/Sparkle.tar.xz" -C "$destination"
