#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
output=${1:-"$PWD/../build/audio-driver-tests"}
mkdir -p "$output"
clang -mmacosx-version-min=14.0 -std=c17 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fblocks -D OD_HAL_TEST -framework CoreAudio -framework CoreFoundation -framework Security \
    Driver.c DriverTests.c -o "$output/test-driver"
"$output/test-driver"
