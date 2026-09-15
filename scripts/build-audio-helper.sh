#!/bin/bash
# Build the standalone ARM64 helper without resolving the app's SwiftPM graph.
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIRECTORY/require-native-apple-silicon.sh"
require_native_apple_silicon
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
OUTPUT_DIRECTORY="${1:-$REPOSITORY_ROOT/.build/native-audio/helper-14.4}"
mkdir -p "$OUTPUT_DIRECTORY/module-cache"
xcrun swiftc -swift-version 6 -O -whole-module-optimization \
    -target arm64-apple-macosx14.4 \
    -D STENO_STANDALONE_HELPER \
    -module-cache-path "$OUTPUT_DIRECTORY/module-cache" \
    "$REPOSITORY_ROOT"/StenoKit/Sources/StenoAudioEncoding/*.swift \
    "$REPOSITORY_ROOT/StenoKit/Sources/steno-audio-encode/main.swift" \
    -o "$OUTPUT_DIRECTORY/steno-audio-encode"
printf 'Helper: %s/steno-audio-encode\n' "$OUTPUT_DIRECTORY"
xcrun vtool -show-build "$OUTPUT_DIRECTORY/steno-audio-encode"
