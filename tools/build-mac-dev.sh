#!/bin/bash
# Build the native macOS Debug sender with Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
deps="$root/build/dev-deps"
derived="$root/build/macos-dev"
destination="$root/build/Build/Products/Debug"
app_name="OpenDisplay Dev"
app="$destination/$app_name.app"
sdk="${OPEN_DISPLAY_MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
cmake="$deps/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake"
boringssl_revision=$(sed -n 's#.*codeload\.github\.com/google/boringssl/tar\.gz/\([a-f0-9]*\).*#\1#p' Pairing/CMakeLists.txt)
boringssl="$deps/boringssl-$boringssl_revision"
arch=$(uname -m)

for input in "$sdk/SDKSettings.plist" "$cmake" "$deps/Sparkle.framework/Sparkle" "$boringssl/CMakeLists.txt"; do
    if [[ ! -e "$input" ]]; then
        printf 'Missing macOS development dependency: %s\n' "$input" >&2
        exit 1
    fi
done
if pgrep -x "$app_name" >/dev/null 2>&1; then
    printf 'Quit OpenDisplay Dev before rebuilding it.\n' >&2
    exit 1
fi

mkdir -p "$derived" "$destination"
stage=$(mktemp -d "$derived/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$app_name.app"
contents="$bundle/Contents"
mkdir -p "$contents/"{MacOS,Frameworks,Resources}

minimum=$(ruby -ryaml -e 'puts YAML.load_file("project.yml").fetch("targets").fetch("OpenSidecarMac").fetch("deploymentTarget")')
pairing="$derived/lan-pairing-$arch"
"$cmake" -S "$root/Pairing" -B "$pairing" -DCMAKE_BUILD_TYPE=Release \
    "-DCMAKE_OSX_SYSROOT=$sdk" "-DCMAKE_OSX_ARCHITECTURES=$arch" \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$minimum" "-DFETCHCONTENT_SOURCE_DIR_BORINGSSL=$boringssl"
"$cmake" --build "$pairing" --target odpair --parallel 4

ditto "$deps/Sparkle.framework" "$contents/Frameworks/Sparkle.framework"
ruby -ryaml -rjson -e '
    project = YAML.load_file("project.yml")
    target = project.fetch("targets").fetch("OpenSidecarMac")
    debug = target.fetch("settings").fetch("configs").fetch("Debug")
    settings = project.fetch("settings").fetch("base")
    info = target.fetch("info").fetch("properties").merge(
      "CFBundleDisplayName" => debug.fetch("BUNDLE_DISPLAY_NAME"),
      "CFBundleExecutable" => debug.fetch("PRODUCT_NAME"),
      "CFBundleIdentifier" => debug.fetch("PRODUCT_BUNDLE_IDENTIFIER"),
      "CFBundleName" => debug.fetch("PRODUCT_NAME"),
      "CFBundleInfoDictionaryVersion" => "6.0",
      "CFBundlePackageType" => "APPL",
      "CFBundleIconFile" => "AppIcon",
      "CFBundleShortVersionString" => settings.fetch("MARKETING_VERSION"),
      "CFBundleVersion" => settings.fetch("CURRENT_PROJECT_VERSION"),
      "LSMinimumSystemVersion" => target.fetch("deploymentTarget"),
      "SUEnableAutomaticChecks" => false
    )
    puts JSON.generate(info)
' > "$stage/Info.json"
plutil -convert xml1 -o "$contents/Info.plist" "$stage/Info.json"

sips -s format icns Mac/Assets.xcassets/AppIcon-Dev.appiconset/icon_512.png \
    --out "$contents/Resources/AppIcon.icns" >/dev/null
cp Pairing/licenses/BoringSSL.txt "$contents/Resources/"
CONFIGURATION=Debug SRCROOT="$root" DERIVED_FILE_DIR="$derived" TARGET_BUILD_DIR="$stage" \
    UNLOCALIZED_RESOURCES_FOLDER_PATH="$app_name.app/Contents/Resources" bash MacAudioDriver/embed-package.sh

if ! xcrun swiftc -sdk "$sdk" -swift-version 5 -D DEBUG -target "$arch-apple-macosx$minimum" \
    -module-name OpenSidecarMac -module-cache-path "$derived/swift-cache" \
    -F "$contents/Frameworks" -I Pairing/include -import-objc-header Mac/OpenSidecarMac-Bridging-Header.h \
    Mac/*.swift Shared/*.swift "$pairing/libodpair.a" "$pairing/_deps/boringssl-build/libcrypto.a" \
    -lc++ -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -o "$contents/MacOS/$app_name" > "$derived/swift.log" 2>&1; then
    cat "$derived/swift.log" >&2
    exit 1
fi

identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$contents/Info.plist")
codesign --force --sign - --requirements "=designated => identifier \"$identifier\"" \
    --entitlements Mac/OpenSidecarMac.entitlements "$bundle"
codesign --verify --deep --strict "$bundle"

if [[ -e "$app" ]]; then
    mv "$app" "$stage/previous.app"
    if ! mv "$bundle" "$app"; then
        mv "$stage/previous.app" "$app"
        exit 1
    fi
else
    mv "$bundle" "$app"
fi
printf 'Built %s\n' "$app"
