#!/bin/bash
# Exercise the shared helper sources independently of the app/model package graph.
set -euo pipefail
SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIRECTORY/require-native-apple-silicon.sh"
require_native_apple_silicon
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
TEST_ROOT="$REPOSITORY_ROOT/.build/native-audio/standalone-tests"
mkdir -p "$TEST_ROOT/Sources/StenoAudioEncoding" "$TEST_ROOT/Sources/StenoExchange" "$TEST_ROOT/Tests/NativeAudioHelperTests"
# These are generated build inputs, not a second maintained implementation.
cp "$REPOSITORY_ROOT"/StenoKit/Sources/StenoAudioEncoding/*.swift "$TEST_ROOT/Sources/StenoAudioEncoding/"
cp "$REPOSITORY_ROOT/StenoKit/Tests/StenoExchangeTests/NativeAudioHelperTests.swift" "$TEST_ROOT/Tests/NativeAudioHelperTests/"
cp "$REPOSITORY_ROOT/StenoKit/Sources/StenoExchange/LegacyAudioCodecAliases.swift" "$TEST_ROOT/Sources/StenoExchange/"
cp "$REPOSITORY_ROOT/StenoKit/Tests/StenoExchangeTests/WebMOpusReaderTests.swift" "$TEST_ROOT/Tests/NativeAudioHelperTests/"
cat > "$TEST_ROOT/Tests/NativeAudioHelperTests/TemporaryDirectory.swift" <<'SWIFT'
import Foundation
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
SWIFT
cat > "$TEST_ROOT/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeAudioHelperValidation", platforms: [.macOS("14.4")], targets: [
    .target(name: "StenoAudioEncoding"),
    .target(name: "StenoExchange", dependencies: ["StenoAudioEncoding"]),
    .testTarget(name: "NativeAudioHelperTests", dependencies: ["StenoAudioEncoding", "StenoExchange"]),
])
PACKAGE
swift test --package-path "$TEST_ROOT" --no-parallel
