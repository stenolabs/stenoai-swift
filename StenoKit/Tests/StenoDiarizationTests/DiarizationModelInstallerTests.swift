@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import Testing
@testable import StenoDiarization

@Suite("Diarization model installer")
struct DiarizationModelInstallerTests {
    private let locale = Locale(identifier: "de-DE")

    private func emptyDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the provider builds without a download switch and reports what is missing")
    func providerReportsMissing() throws {
        let directory = try emptyDirectory()
        // Kein Audio noetig: geprueft wird die Modellabfrage, nicht die
        // Inferenz. StenoDiarizationTests fuehrt keine Fixtures.
        let missing = missingModelURLs(
            required: [directory.appendingPathComponent("sortformer.mlmodelc")],
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        #expect(missing.count == 1)
    }

    @Test("install runs exactly one download and then verifies checksums")
    func installDownloadsOnce() async throws {
        let directory = try emptyDirectory()
        let counter = DownloadCounter()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { baseDirectory, _ in
                #expect(diarizationModelInstallationIsIncomplete(in: baseDirectory))
                await counter.increment()
            }
        )
        try await installer.install(for: locale) { _ in }
        #expect(await counter.value == 1)
        #expect(!diarizationModelInstallationIsIncomplete(in: directory))
    }

    @Test("a failing download does not leave the installer claiming readiness")
    func failedDownloadKeepsMissing() async throws {
        let directory = try emptyDirectory()
        let apparentlyCompleteBundle = directory
            .appendingPathComponent("Sortformer_v2.1.mlmodelc", isDirectory: true)
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { baseDirectory, _ in
                try FileManager.default.createDirectory(
                    at: apparentlyCompleteBundle,
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(
                    to: apparentlyCompleteBundle.appendingPathComponent("coremldata.bin")
                )
                #expect(diarizationModelInstallationIsIncomplete(in: baseDirectory))
                throw DiarizationError.modelInstallationFailed("no network")
            }
        )
        await #expect(throws: DiarizationError.self) {
            try await installer.install(for: locale) { _ in }
        }
        let readiness = await installer.readiness(for: [locale])
        #expect(!readiness.isReady(for: locale))
        // Der Name geht in die Oberflaeche, dort steht kein Dateiname.
        #expect(readiness.missingNames(for: locale) == ["Speaker separation"])
        #expect(diarizationModelInstallationIsIncomplete(in: directory))
        #expect(!modelBundleIsComplete(
            apparentlyCompleteBundle,
            fileManager: .default,
            installationRoot: directory
        ))
    }

    @Test("an already verified installation is not touched by another install request")
    func verifiedInstallationSkipsDownload() async throws {
        let directory = try emptyDirectory()
        try makeCompleteModelBundles(in: directory)
        let checksumFile = directory.appendingPathComponent("weights.bin")
        try Data("gut".utf8).write(to: checksumFile)
        let counter = DownloadCounter()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [
                "weights.bin": "77562953d4c8dc074e55e73375e64f65fef94dcddd39381abb5be1ee250e2b1f",
            ]),
            download: { _, _ in
                await counter.increment()
                throw DiarizationError.modelInstallationFailed("no network")
            }
        )

        try await installer.install(for: locale) { _ in }

        #expect(await counter.value == 0)
        #expect(await installer.readiness(for: [locale]).isReady(for: locale))
        #expect(!diarizationModelInstallationIsIncomplete(in: directory))
    }

    @Test("a failed install exposes model files that completed and passed verification")
    func failedInstallRestoresVerifiedInstallation() async throws {
        let directory = try emptyDirectory()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [
                "weights.bin": "77562953d4c8dc074e55e73375e64f65fef94dcddd39381abb5be1ee250e2b1f",
            ]),
            download: { baseDirectory, _ in
                try makeCompleteModelBundles(in: baseDirectory)
                try Data("gut".utf8).write(
                    to: baseDirectory.appendingPathComponent("weights.bin")
                )
                throw DiarizationError.modelInstallationFailed("connection lost")
            }
        )

        await #expect(throws: DiarizationError.self) {
            try await installer.install(for: locale) { _ in }
        }

        #expect(await installer.readiness(for: [locale]).isReady(for: locale))
        #expect(!diarizationModelInstallationIsIncomplete(in: directory))
    }

    @Test("the provider reports missing models while a partial install is marked")
    func providerCannotLoadPartialInstallation() async throws {
        let directory = try emptyDirectory()
        for bundle in try requiredBundleURLs(baseDirectory: directory) {
            try FileManager.default.createDirectory(
                at: bundle,
                withIntermediateDirectories: true
            )
            try Data("partial".utf8).write(
                to: bundle.appendingPathComponent("coremldata.bin")
            )
        }
        try markDiarizationModelInstallationIncomplete(in: directory)
        let audioURL = directory.appendingPathComponent("input.caf")
        try writeTestAudio(to: audioURL)
        let provider = FluidSortformerProvider(modelCacheDirectory: directory)

        do {
            _ = try await provider.diarize(audioURL, hints: .init())
            Issue.record("Expected the incomplete installation to stay unavailable")
        } catch let error as DiarizationError {
            guard case .modelsNotInstalled(let missing) = error else {
                Issue.record("Expected modelsNotInstalled, got \(error)")
                return
            }
            #expect(missing.count == 3)
        }
    }

    @Test("the download reports its progress through to the caller")
    func reportsDownloadProgress() async throws {
        let directory = try emptyDirectory()
        let recorder = ProgressRecorder()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { _, progress in
                progress(0.25)
                progress(0.5)
            }
        )
        try await installer.install(for: locale) { recorder.record($0.fraction) }

        let recorded = recorder.recorded
        #expect(recorded.first == 0)
        #expect(recorded.last == 1)
        // Zwischenwerte, nicht nur der Sprung von 0 auf 1.
        #expect(recorded.contains { $0 > 0 && $0 < 1 })
        #expect(recorded == recorded.sorted())
    }

    @Test("a second caller sees the progress of the install it waits for")
    func secondCallerSeesProgress() async throws {
        let directory = try emptyDirectory()
        let downloadStarted = Signal()
        let downloadMayFinish = Signal()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { _, progress in
                progress(0.5)
                downloadStarted.raise()
                await downloadMayFinish.wait()
            }
        )

        let first = Task { try await installer.install(for: locale) { _ in } }
        await downloadStarted.wait()

        let recorder = ProgressRecorder()
        let second = Task {
            try await installer.install(for: locale) { recorder.record($0.fraction) }
        }
        // Erst wenn der Zweite angemeldet ist, darf der Download enden.
        while await installer.observerCount < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }
        downloadMayFinish.raise()

        try await first.value
        try await second.value

        #expect(!recorder.recorded.isEmpty)
        #expect(recorder.recorded.last == 1)
        #expect(await installer.observerCount == 0)
    }

    @Test("a cancelled install stops the running download")
    func cancelStopsDownload() async throws {
        let directory = try emptyDirectory()
        let downloadStarted = Signal()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [:]),
            download: { _, _ in
                downloadStarted.raise()
                try await Task.sleep(for: .seconds(30))
            }
        )

        let install = Task { try await installer.install(for: locale) { _ in } }
        await downloadStarted.wait()
        await installer.cancelInstall()

        await #expect(throws: (any Error).self) {
            try await install.value
        }
        let readiness = await installer.readiness(for: [locale])
        #expect(!readiness.isReady(for: locale))
    }

    @Test("only the two Sortformer variants Steno uses are required")
    func requiresBothSortformerVariants() throws {
        let directory = try emptyDirectory()
        let names = try requiredBundleURLs(baseDirectory: directory)
            .map(\.lastPathComponent)

        #expect(names.count == 4)
        #expect(names.contains("Sortformer_v2.1.mlmodelc"))
        #expect(names.contains("SortformerNvidiaHigh_v2.mlmodelc"))
        #expect(names.contains("pyannote_segmentation.mlmodelc"))
        #expect(names.contains("wespeaker_v2.mlmodelc"))
    }

    @Test("bundled checksums cover exactly the model bundles the installer downloads")
    func bundledChecksumsMatchDownloadedBundles() throws {
        let directory = try emptyDirectory()
        let required = Set(try requiredBundleURLs(baseDirectory: directory).map {
            String($0.path.dropFirst(directory.path.count + 1))
        })
        let entries = try ModelChecksumManifest.bundled().entries
        let covered = Set(entries.keys.compactMap { path -> String? in
            guard let boundary = path.range(of: ".mlmodelc/") else { return nil }
            return String(path[..<boundary.lowerBound]) + ".mlmodelc"
        })

        // Derive paths from FluidAudio so a dependency layout change cannot
        // silently leave verification pointing at unused legacy bundles.
        #expect(covered == required)
        for bundle in required {
            #expect(entries.keys.contains {
                $0.hasPrefix(bundle + "/") && $0.contains("/weights/")
            })
        }
    }

    @Test("the advertised download size matches the bundles that are fetched")
    func advertisedSizeMatchesBundles() async {
        let installer = DiarizationModelInstaller(
            manifest: ModelChecksumManifest(entries: [:]),
            download: { _, _ in }
        )
        let description = installer.bundleDescription

        #expect(description.source == .huggingFace)
        // Gemessen, nicht geschaetzt: rund 486 MiB fuer beide Sortformer-
        // Varianten plus alles, was der Diarizer-Aufruf anfordert.
        #expect(description.approximateBytes == DiarizationModelBytes.total)
        // Zweiseitig, und an den beiden Fehlwerten ausgerichtet, die in
        // dieser Aufgabe wirklich auf dem Tisch lagen - eine blosse
        // Plausibilitaetsschranke liesse beide durch:
        //   509_628_416: nur die zwei Modelle, die der Provider oeffnet, die
        //                Wurzel-JSON fehlen (der behobene Fehler).
        //   531_456_000: der gefuellte Modellordner, also auch Dateien, die
        //                dieser Aufruf nie anfordert.
        // Gemessen sind es 509_902_848; dazwischen bleibt Luft fuer die
        // Blockrundung, aber keine fuer die beiden Fehlwerte.
        #expect(description.approximateBytes > 509_700_000)
        #expect(description.approximateBytes < 510_500_000)
    }

    @Test("a file with wrong bytes is replaced instead of failing forever")
    func wrongBytesAreReplaced() async throws {
        let directory = try emptyDirectory()
        let target = directory.appendingPathComponent("weights.bin")
        let counter = DownloadCounter()
        // Erster Lauf schreibt falsche Bytes, jeder weitere die richtigen.
        // Das ist die Lage nach einem verfaelschten Download: FluidAudios
        // Downloader ueberspringt jeden vorhandenen Zielpfad, ohne Loeschen
        // pruefte jeder weitere Klick dieselben falschen Bytes.
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [
                "weights.bin": "77562953d4c8dc074e55e73375e64f65fef94dcddd39381abb5be1ee250e2b1f",
            ]),
            download: { base, _ in
                let url = base.appendingPathComponent("weights.bin")
                guard !FileManager.default.fileExists(atPath: url.path) else { return }
                let isFirst = await counter.value == 0
                await counter.increment()
                try Data((isFirst ? "falsch" : "gut").utf8).write(to: url)
            }
        )

        let attempts = AttemptRecorder()
        try await installer.install(for: locale) { attempts.record($0) }

        #expect(await counter.value == 2)
        #expect(try Data(contentsOf: target) == Data("gut".utf8))
        // Der Reparaturlauf muss sich als neuer Anlauf ausweisen. Ohne das
        // verwirft die Oberflaeche seinen Fortschritt als ueberholten
        // Rueckruf, und der Balken bliebe waehrend des ganzen erneuten
        // Ladens stehen.
        //
        // Zwei **verschiedene** Nummern, nicht bloss eine von null
        // verschiedene: schon der normale Start setzt das Relais zurueck und
        // zaehlt damit hoch. Eine Schranke gegen null haette hier keine
        // Zaehne.
        let attemptNumbers = Set(attempts.recorded.map(\.attempt))
        #expect(attemptNumbers.count == 2)
        let lastAttempt = try #require(attemptNumbers.max())
        let repairStart = attempts.recorded.first { $0.attempt == lastAttempt }
        #expect(repairStart?.fraction == 0)
    }

    @Test("bytes that stay wrong still fail, they do not loop")
    func persistentlyWrongBytesStillFail() async throws {
        let directory = try emptyDirectory()
        let counter = DownloadCounter()
        let installer = DiarizationModelInstaller(
            modelCacheDirectory: directory,
            manifest: ModelChecksumManifest(entries: [
                "weights.bin": "77562953d4c8dc074e55e73375e64f65fef94dcddd39381abb5be1ee250e2b1f",
            ]),
            download: { base, _ in
                let url = base.appendingPathComponent("weights.bin")
                guard !FileManager.default.fileExists(atPath: url.path) else { return }
                await counter.increment()
                try Data("falsch".utf8).write(to: url)
            }
        )

        await #expect(throws: ModelIntegrityError.self) {
            try await installer.install(for: locale) { _ in }
        }
        // Genau ein Reparaturversuch. Ohne diese Zusicherung koennte die
        // Reparatur endlos weiterlaufen und der Nutzer saehe nie einen Fehler.
        #expect(await counter.value == 2)
    }
}

private func makeCompleteModelBundles(in directory: URL) throws {
    for bundle in try requiredBundleURLs(baseDirectory: directory) {
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        try Data("complete".utf8).write(
            to: bundle.appendingPathComponent("coremldata.bin")
        )
    }
}

private func writeTestAudio(to url: URL) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: 1_600
    ))
    buffer.frameLength = 1_600
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

actor DownloadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Sammelt Fortschrittswerte aus fremden Kontexten ohne Umweg ueber einen
/// Aktor: der Rueckruf ist synchron, ein `await` wuerde die Reihenfolge
/// verwischen, die hier gerade geprueft wird.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        values.append(fraction)
    }

    var recorded: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Einmal gesetzte Marke, auf die gewartet werden kann. Ersetzt festes
/// Schlafen in den nebenlaeufigen Tests.
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var isRaised = false

    func raise() {
        lock.lock()
        defer { lock.unlock() }
        isRaised = true
    }

    var raised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRaised
    }

    func wait() async {
        while !raised {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

/// Haelt die Fortschrittsmeldungen samt Laufnummer fest.
final class AttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelInstallProgress] = []

    func record(_ progress: ModelInstallProgress) {
        lock.lock()
        defer { lock.unlock() }
        values.append(progress)
    }

    var recorded: [ModelInstallProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
