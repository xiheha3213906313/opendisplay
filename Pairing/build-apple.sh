#!/bin/bash
set -euo pipefail

# One cache per target, platform and architecture set. Uses the Xcode SDK,
# not the host SDK, for device and simulator archives.
build_dir="${DERIVED_FILE_DIR}/lan-pairing"
configure=(
    -S "${SRCROOT}/Pairing" -B "$build_dir"
    -DCMAKE_BUILD_TYPE=Release "-DCMAKE_OSX_SYSROOT=$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
    "-DCMAKE_OSX_ARCHITECTURES=${ARCHS// /;}"
    # Set before project() so the iOS platform file does not turn bssl into
    # a bundle. See Pairing/CMakeLists.txt.
    -DCMAKE_MACOSX_BUNDLE=OFF
)
if [[ "$PLATFORM_NAME" == iphone* ]]; then
    configure+=(-DCMAKE_SYSTEM_NAME=iOS "-DCMAKE_OSX_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET")
else
    configure+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET")
fi
if [[ -n "${OD_BORINGSSL_SOURCE:-}" ]]; then
    configure+=("-DFETCHCONTENT_SOURCE_DIR_BORINGSSL=$OD_BORINGSSL_SOURCE")
fi
cmake "${configure[@]}"
cmake --build "$build_dir" --target odpair --parallel 4
