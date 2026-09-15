// swift-tools-version: 6.3

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "StenoKit",
    platforms: [
        .macOS(.v26),
        // The eight portable libraries build and test on iOS unchanged; the
        // iOS app links those and never builds StenoMacAudio, which stays
        // macOS-only because CoreAudio's process tap does not exist on iOS.
        .iOS(.v26),
    ],
    products: [
        .library(name: "StenoDomain", targets: ["StenoDomain"]),
        .library(name: "StenoLibrary", targets: ["StenoLibrary"]),
        .library(name: "StenoAudioEncoding", targets: ["StenoAudioEncoding"]),
        .library(name: "StenoAudioCore", targets: ["StenoAudioCore"]),
        .library(name: "StenoMacAudio", targets: ["StenoMacAudio"]),
        .library(name: "StenoTranscription", targets: ["StenoTranscription"]),
        .library(name: "StenoDiarization", targets: ["StenoDiarization"]),
        .library(name: "StenoIdentity", targets: ["StenoIdentity"]),
        .library(name: "StenoExchange", targets: ["StenoExchange"]),
        .library(name: "StenoIntelligence", targets: ["StenoIntelligence"]),
        .library(name: "StenoPipeline", targets: ["StenoPipeline"]),
        .library(name: "StenoDemo", targets: ["StenoDemo"]),
        .executable(name: "steno-audio-encode", targets: ["steno-audio-encode"]),
        .executable(name: "steno-smoke", targets: ["steno-smoke"]),
        .executable(name: "steno-transcribe", targets: ["steno-transcribe"]),
        .executable(name: "steno-live-transcribe", targets: ["steno-live-transcribe"]),
        .executable(name: "steno-diarize-bench", targets: ["steno-diarize-bench"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.6"
        ),
    ],
    targets: [
        .executableTarget(name: "steno-audio-encode", dependencies: ["StenoAudioEncoding"], swiftSettings: strictConcurrencySettings),
        .target(name: "StenoAudioEncoding", swiftSettings: strictConcurrencySettings),
        .target(
            name: "StenoDomain",
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoLibrary",
            dependencies: ["StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        // Everything about recording that is not tied to macOS: writing the
        // tracks, crash recovery, disk headroom, levels, and the session that
        // orchestrates them. iOS records with the same code as the Mac, which
        // is the whole point - crash safety is not something to reimplement
        // twice and get subtly different.
        .target(
            name: "StenoAudioCore",
            dependencies: ["StenoDomain", "StenoLibrary"],
            swiftSettings: strictConcurrencySettings
        ),
        // What genuinely only exists on macOS: the CoreAudio process tap for
        // system audio, the CoreAudio permission check, and sleep prevention.
        .target(
            name: "StenoMacAudio",
            dependencies: ["StenoAudioCore", "StenoDomain", "StenoLibrary"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoTranscription",
            dependencies: [
                "StenoDomain",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoDiarization",
            dependencies: [
                "StenoDomain",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.process("Resources")],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoIdentity",
            dependencies: ["StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoExchange",
            dependencies: ["StenoDomain", "StenoIdentity", "StenoLibrary", "StenoAudioEncoding"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoIntelligence",
            dependencies: ["StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoPipeline",
            dependencies: [
                "StenoDomain",
                "StenoLibrary",
                "StenoTranscription",
                "StenoDiarization",
                "StenoIdentity",
                "StenoIntelligence",
                "StenoExchange",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoDemo",
            dependencies: ["StenoDomain", "StenoLibrary"],
            resources: [.copy("Resources/DemoDataset")],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "StenoLiveBenchmarkSupport",
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "steno-diarize-bench",
            dependencies: ["StenoDiarization"],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "steno-transcribe",
            dependencies: ["StenoTranscription"],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "steno-live-transcribe",
            dependencies: ["StenoLiveBenchmarkSupport", "StenoTranscription"],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "steno-smoke",
            dependencies: [
                "StenoDomain", "StenoLibrary", "StenoPipeline", "StenoTranscription",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoDomainTests",
            dependencies: ["StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoDemoTests",
            dependencies: ["StenoDemo", "StenoDomain", "StenoLibrary"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoLiveBenchmarkSupportTests",
            dependencies: ["StenoLiveBenchmarkSupport"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoLibraryTests",
            dependencies: ["StenoAudioCore", "StenoLibrary", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoAudioCoreTests",
            dependencies: ["StenoAudioCore", "StenoTranscription", "StenoLibrary", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoMacAudioTests",
            dependencies: ["StenoMacAudio", "StenoLibrary", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoTranscriptionTests",
            dependencies: ["StenoTranscription", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoDiarizationTests",
            dependencies: ["StenoDiarization", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoIdentityTests",
            dependencies: ["StenoIdentity", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoExchangeTests",
            dependencies: [
                "StenoExchange", "StenoDomain", "StenoIdentity", "StenoLibrary", "StenoAudioEncoding",
            ],
            resources: [.process("Fixtures")],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoIntelligenceTests",
            dependencies: ["StenoIntelligence", "StenoDomain"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoPipelineTests",
            dependencies: [
                "StenoPipeline",
                "StenoTranscription",
                "StenoDiarization",
                "StenoIdentity",
                "StenoIntelligence",
                "StenoExchange",
                "StenoLibrary",
                "StenoDomain",
            ],
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
