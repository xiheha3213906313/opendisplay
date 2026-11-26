#!/bin/bash
set -euo pipefail

version="${1:?Pass the macOS version}"
source_dir="${2:?Pass the directory containing both DMGs}"
output_dir="${3:?Pass a destination for the installers and manifest}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]

stage="$(mktemp -d)"
mount="$stage/mount"
mounted=false
cleanup() {
    if "$mounted"; then hdiutil detach "$mount" -quiet || true; fi
    rm -rf "$stage"
}
trap cleanup EXIT
mkdir -p "$mount"

for product in sender receiver; do
    if [[ "$product" == sender ]]; then
        asset=OpenDisplay.dmg app=OpenDisplay identifier=com.xiheha.opensidecar.mac
    else
        asset=OpenDisplayReceiver.dmg app="OpenDisplay Receiver" identifier=com.xiheha.opensidecar.mac.receiver
    fi
    cp "$source_dir/$asset" "$stage/$asset"
    hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$stage/$asset" -quiet
    mounted=true
    bundle="$mount/$app.app"
    plist="$bundle/Contents/Info.plist"
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" != "$identifier" ||
          "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" != "$version" ||
          ! "$build" =~ ^[1-9][0-9]*$ ]]; then
        echo "The bundle identity or version in $asset does not match the update" >&2
        exit 1
    fi
    lipo -verify_arch arm64 "$bundle/Contents/MacOS/$app"
    lipo -verify_arch x86_64 "$bundle/Contents/MacOS/$app"
    codesign --verify --deep --strict "$bundle"
    hdiutil detach "$mount" -quiet
    mounted=false
    if [[ "$product" == sender ]]; then sender_build="$build"; else receiver_build="$build"; fi
done

mkdir -p "$output_dir"
cp "$stage/OpenDisplay.dmg" "$stage/OpenDisplayReceiver.dmg" "$output_dir/"
printf '{"version":"%s","senderBuild":%s,"receiverBuild":%s}\n' \
    "$version" "$sender_build" "$receiver_build" > "$output_dir/latest.json"
