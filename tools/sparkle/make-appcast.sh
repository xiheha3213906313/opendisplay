#!/bin/bash
set -euo pipefail

if [[ $# != 4 ]]; then
    echo "Usage: $0 sparkle-directory vX.Y.Z sender|receiver output-directory" >&2
    exit 2
fi

tools="$1/bin"
scripts="$(cd "$(dirname "$0")" && pwd)"
tag="$2"
output="$4"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
repo=xiheha3213906313/opendisplay
case "$3" in
    sender)
        app=OpenDisplay
        asset=OpenDisplay.dmg
        feed=appcast.xml
        identifier=com.xiheha.opensidecar.mac
        minimum=14.0
        ;;
    receiver)
        app="OpenDisplay Receiver"
        asset=OpenDisplayReceiver.dmg
        feed=appcast-receiver.xml
        identifier=com.xiheha.opensidecar.mac.receiver
        minimum=12.0
        ;;
    *) exit 2 ;;
esac

: "${SPARKLE_PRIVATE_KEY:?Configure the Sparkle GitHub Actions secret}"
: "${SPARKLE_PUBLIC_KEY:?Configure the Sparkle GitHub Actions variable}"
stage="$(mktemp -d)"
mount="$stage/mount"
mounted=false
cleanup() {
    if "$mounted"; then hdiutil detach "$mount" -quiet || true; fi
    rm -rf "$stage"
}
trap cleanup EXIT
mkdir -p "$stage/archive" "$mount" "$output"
gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$stage/archive"
image="$stage/archive/$asset"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$image" -quiet
mounted=true
bundle="$mount/$app.app"
plist="$bundle/Contents/Info.plist"
read_info() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist"; }
build="$(read_info CFBundleVersion)"
if [[ "$(read_info CFBundleIdentifier)" != "$identifier" ||
      "$(read_info CFBundleShortVersionString)" != "${tag#v}" ||
      "$(read_info LSMinimumSystemVersion)" != "$minimum" ||
      "$(read_info SUFeedURL)" != "https://raw.githubusercontent.com/$repo/sparkle-feeds/$feed" ||
      "$(read_info SUPublicEDKey)" != "$SPARKLE_PUBLIC_KEY" ||
      "$(read_info SURequireSignedFeed)" != true ||
      "$(read_info SUVerifyUpdateBeforeExtraction)" != true ||
      ! "$build" =~ ^[1-9][0-9]*$ ]]; then
    echo "Unexpected bundle identity, version or update settings in $asset" >&2
    exit 1
fi
codesign --verify --deep --strict "$bundle"
hdiutil detach "$mount" -quiet
mounted=false

# Sparkle exports new keys as base64 seeds. Verify the derived public key
# against the one embedded in the downloaded app before signing anything.
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | xcrun swift -module-cache-path "$stage/modules" \
    "$scripts/check-key.swift" "$SPARKLE_PUBLIC_KEY"

prefix="https://github.com/$repo/releases/download/$tag/"
appcast="$stage/archive/$feed"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
    --download-url-prefix "$prefix" --maximum-deltas 0 \
    --link "https://github.com/$repo/releases/tag/$tag" "$stage/archive"

xpath() { xmllint --xpath "string($1)" "$appcast"; }
signature="$(xpath "//enclosure/@*[local-name()='edSignature']")"
if [[ "$(xpath '//enclosure/@url')" != "$prefix$asset" ||
      "$(xpath '//enclosure/@length')" != "$(stat -f '%z' "$image")" ||
      "$(xpath "//item/*[local-name()='version']")" != "$build" || -z "$signature" ]]; then
    echo "The generated appcast does not describe $asset" >&2
    exit 1
fi
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$image" "$signature"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$appcast"
cp "$appcast" "$output/$feed"
