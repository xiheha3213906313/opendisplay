#!/bin/bash
set -euo pipefail

package="${OPEN_DISPLAY_AUDIO_DRIVER_PACKAGE:-}"
if [[ "$CONFIGURATION" == Debug ]]; then
    package=$(bash "$SRCROOT/MacAudioDriver/build-package.sh" debug "$DERIVED_FILE_DIR/AudioDriver")
fi
if [[ -n "$package" ]]; then
    mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
    cp "$package" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/OpenDisplayAudioDriver.pkg"
fi
