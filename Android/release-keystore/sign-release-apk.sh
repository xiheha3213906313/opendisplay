#!/bin/bash
# Sign an unsigned release APK with the repository key, or with the
# ANDROID_KEYSTORE_* environment when those secrets are present.
# Passwords are never printed.
set -euo pipefail

unsigned=${1:?unsigned apk}
out=${2:?signed apk}
here=$(cd "$(dirname "$0")" && pwd)

build_tools=$(find "${ANDROID_HOME:?ANDROID_HOME is required}/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
[ -n "$build_tools" ] || { echo "no Android build-tools under ANDROID_HOME" >&2; exit 1; }
aligned=$(mktemp)
trap 'rm -f "$aligned"' EXIT
"$build_tools/zipalign" -p -f 4 "$unsigned" "$aligned"

if [ -n "${ANDROID_KEYSTORE_BASE64:-}" ]; then
  ks=$(mktemp)
  trap 'rm -f "$aligned" "$ks"' EXIT
  printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$ks"
  "$build_tools/apksigner" sign \
    --ks "$ks" \
    --ks-pass env:ANDROID_KEYSTORE_PASSWORD \
    --ks-key-alias "$ANDROID_KEY_ALIAS" \
    --key-pass env:ANDROID_KEY_PASSWORD \
    --out "$out" \
    "$aligned"
else
  "$build_tools/apksigner" sign \
    --ks "$here/opendisplay-release.jks" \
    --ks-pass "file:$here/store.password" \
    --ks-key-alias "$(cat "$here/alias")" \
    --key-pass "file:$here/key.password" \
    --out "$out" \
    "$aligned"
fi

"$build_tools/apksigner" verify --print-certs "$out" >/dev/null
echo "signed $out"
