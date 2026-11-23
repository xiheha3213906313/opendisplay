#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

configuration=${1:-debug}
work=${2:-"$PWD/../build/audio-driver"}
reload=${3:-}
version=1.1
case "$configuration" in
    debug)
        bundle_id=app.opendisplay.audio.driver.debug
        driver_name="OpenDisplay Audio Dev"
        application_identity="-"
        installer_sign=()
        ;;
    release)
        bundle_id=app.opendisplay.audio.driver
        driver_name="OpenDisplay Audio"
        : "${AUDIO_DRIVER_SIGNING_IDENTITY:?Developer ID Application identity required}"
        : "${AUDIO_INSTALLER_SIGNING_IDENTITY:?Developer ID Installer identity required}"
        application_identity=$AUDIO_DRIVER_SIGNING_IDENTITY
        installer_sign=(--sign "$AUDIO_INSTALLER_SIGNING_IDENTITY")
        ;;
    *) printf 'Expected debug or release configuration\n' >&2; exit 2 ;;
esac

mkdir -p "$work"
work=$(cd "$work" && pwd -P)
bundle="$work/$driver_name.driver"
component="$work/Driver-component.pkg"
package="$work/$driver_name.pkg"
factory=D3FCF3E0-31ED-4FA7-BD68-6D42191DA837
if [[ "$configuration" == release ]]; then factory=A58D24CF-8453-4E10-B726-609709247792; fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>OpenDisplayAudio</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>$driver_name</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFPlugInFactories</key><dict><key>$factory</key><string>OpenDisplayAudio_Create</string></dict>
    <key>CFPlugInTypes</key>
    <dict><key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>$factory</string></array></dict>
</dict>
</plist>
PLIST
clang -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
    -std=c17 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -fblocks \
    -D "OD_BUNDLE_ID=\"$bundle_id\"" -framework CoreAudio -framework CoreFoundation \
    Driver.c -o "$bundle/Contents/MacOS/OpenDisplayAudio"
cp APPLE-LICENSE.txt ../LICENSE ../Audio-attribution.md "$bundle/Contents/Resources/"
codesign --force --sign "$application_identity" "$bundle"
codesign --verify --strict "$bundle"
plutil -lint "$bundle/Contents/Info.plist"

# Restrict the package to this bundle at a fixed system location.
conclusion='onConclusion="RequireRestart"'
scripts=()
if [[ "$configuration" == debug && "$reload" == "--reload-audio" ]]; then
    mkdir -p "$work/scripts"
    cat > "$work/scripts/postinstall" <<'POSTINSTALL'
#!/bin/sh
# Reload the plug-ins on the running volume after an explicit test install.
if [ "$3" = "/" ]; then
    /usr/bin/killall -TERM coreaudiod || true
fi
POSTINSTALL
    chmod 755 "$work/scripts/postinstall"
    scripts=(--scripts "$work/scripts")
    conclusion=''
fi
pkgbuild --component "$bundle" --install-location /Library/Audio/Plug-Ins/HAL \
    --identifier "$bundle_id.pkg" --version "$version" ${scripts[@]+"${scripts[@]}"} "$component"
cat > "$work/Distribution.xml" <<DISTRIBUTION
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
    <title>$driver_name</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>
    <volume-check><allowed-os-versions><os-version min="14.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="driver"/></choices-outline>
    <choice id="driver" title="$driver_name" visible="false"><pkg-ref id="$bundle_id.pkg"/></choice>
    <pkg-ref id="$bundle_id.pkg" version="$version" auth="Root" $conclusion>Driver-component.pkg</pkg-ref>
</installer-gui-script>
DISTRIBUTION
productbuild --distribution "$work/Distribution.xml" --package-path "$work" \
    ${installer_sign[@]+"${installer_sign[@]}"} "$package"
printf '%s\n' "$package"
