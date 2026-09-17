import Foundation
import Testing
@testable import steno_macos

@Suite("Storage location")
struct StorageLocationTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "StorageLocationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Resolution order

    @Test("absent key resolves to the standard Application Support location")
    func absentKeyFallsBackToStandard() throws {
        let defaults = try makeDefaults()

        let url = StorageLocation.effectiveLibraryDirectory(
            defaults: defaults,
            environment: [:]
        )

        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        #expect(
            url.standardizedFileURL.path
                == base.appendingPathComponent("Steno/Library", isDirectory: true)
                .standardizedFileURL.path
        )
    }

    @Test("environment override beats a custom path and the standard location")
    func environmentOverrideWins() throws {
        let defaults = try makeDefaults()
        StorageLocation.setCustomPath("/tmp/custom-library", defaults: defaults)

        let url = StorageLocation.effectiveLibraryDirectory(
            defaults: defaults,
            environment: [StorageLocation.environmentOverrideKey: "/tmp/env-library"]
        )

        #expect(url.path == "/tmp/env-library")
    }

    @Test("custom path beats the standard location and expands tilde")
    func customPathWinsAndExpandsTilde() throws {
        let defaults = try makeDefaults()
        StorageLocation.setCustomPath("~/Meetings/Library", defaults: defaults)

        let url = StorageLocation.effectiveLibraryDirectory(
            defaults: defaults,
            environment: [:]
        )

        #expect(
            url.standardizedFileURL.path
                == home.appendingPathComponent("Meetings/Library").standardizedFileURL.path
        )
    }

    @Test("blank custom path counts as unset")
    func blankCustomPathIsUnset() throws {
        let defaults = try makeDefaults()
        defaults.set("   ", forKey: StorageLocation.customPathDefaultsKey)

        #expect(StorageLocation.customPath(defaults: defaults) == nil)
    }

    @Test("setCustomPath round-trips and nil removes the key entirely")
    func setCustomPathRoundTrip() throws {
        let defaults = try makeDefaults()

        StorageLocation.setCustomPath(" /tmp/library ", defaults: defaults)
        #expect(StorageLocation.customPath(defaults: defaults) == "/tmp/library")

        StorageLocation.setCustomPath(nil, defaults: defaults)
        #expect(defaults.object(forKey: StorageLocation.customPathDefaultsKey) == nil)
    }

    // MARK: - Validation

    @Test("relative paths are rejected without touching the filesystem")
    func relativePathRejected() {
        let failure = StorageLocation.validate(
            path: "relative/folder",
            bundleURL: URL(fileURLWithPath: "/tmp/Steno.app"),
            fileManager: .default
        )
        #expect(failure == .notAbsolute(path: "relative/folder"))
    }

    @Test("an existing writable directory validates cleanly")
    func existingDirectoryAccepted() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }

        #expect(
            StorageLocation.validate(
                path: root.url.path,
                bundleURL: URL(fileURLWithPath: "/tmp/Steno.app"),
                fileManager: .default
            ) == nil
        )
    }

    @Test("a missing directory under an existing parent is created and accepted")
    func missingCreatableDirectoryAccepted() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let candidate = root.url.appendingPathComponent("nested/library")

        #expect(
            StorageLocation.validate(
                path: candidate.path,
                bundleURL: URL(fileURLWithPath: "/tmp/Steno.app"),
                fileManager: .default
            ) == nil
        )
        var isDirectory: ObjCBool = false
        #expect(
            FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue)
    }

    @Test("a regular file in place of the directory is rejected")
    func filePathRejected() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let fileURL = root.url.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: fileURL)

        #expect(
            StorageLocation.validate(
                path: fileURL.path,
                bundleURL: URL(fileURLWithPath: "/tmp/Steno.app"),
                fileManager: .default
            ) == .notADirectory(path: fileURL.path)
        )
    }

    @Test("an unwritable existing directory is rejected")
    func unwritableDirectoryRejected() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let locked = root.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: locked.path
            )
        }

        #expect(
            StorageLocation.validate(
                path: locked.path,
                bundleURL: URL(fileURLWithPath: "/tmp/Steno.app"),
                fileManager: .default
            ) == .notWritable(path: locked.path)
        )
    }

    @Test("paths inside the app bundle are rejected, sibling names stay allowed")
    func bundleInteriorRejectedButSiblingsAllowed() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let bundleURL = root.url.appendingPathComponent("Steno.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let inside = bundleURL.appendingPathComponent("Contents/Library")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let sibling = root.url.appendingPathComponent("Steno.app2-data")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        #expect(
            StorageLocation.validate(
                path: inside.path,
                bundleURL: bundleURL,
                fileManager: .default
            ) == .insideAppBundle(path: inside.standardizedFileURL.path)
        )
        #expect(
            StorageLocation.validate(
                path: sibling.path,
                bundleURL: bundleURL,
                fileManager: .default
            ) == nil
        )
    }

    // MARK: - Settings form flow

    @MainActor
    @Test("invalid pick surfaces the failure inline and keeps the stored path")
    func invalidPickLeavesSettingUntouched() throws {
        let defaults = try makeDefaults()
        let form = LibraryLocationForm(defaults: defaults)
        StorageLocation.setCustomPath("/tmp/previous", defaults: defaults)

        form.choose(url: URL(fileURLWithPath: "relative"))

        #expect(form.validationFailure != nil)
        #expect(form.validationFailure?.message.isEmpty == false)
        #expect(StorageLocation.customPath(defaults: defaults) == "/tmp/previous")
        #expect(form.hasCustomPath)
    }

    @MainActor
    @Test("valid pick persists the custom path and clear removes it again")
    func validPickPersistsThenClearRemoves() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let defaults = try makeDefaults()
        let form = LibraryLocationForm(defaults: defaults, environment: [:])

        form.choose(url: root.url.appendingPathComponent("chosen"))

        #expect(form.validationFailure == nil)
        #expect(form.hasCustomPath)
        #expect(
            StorageLocation.effectiveLibraryDirectory(defaults: defaults, environment: [:])
                .path == root.url.appendingPathComponent("chosen").path
        )
        #expect(
            form.displayPath == root.url.appendingPathComponent("chosen").path
        )

        form.clear()

        #expect(!form.hasCustomPath)
        #expect(StorageLocation.customPath(defaults: defaults) == nil)
    }

    @Test("the form displays an explicit library override without changing the saved choice")
    @MainActor
    func displayRespectsEnvironmentOverride() throws {
        let root = try TemporaryDirectory()
        defer { root.cleanUp() }
        let defaults = try makeDefaults()
        let override = root.url.appendingPathComponent("isolated-library").path
        let form = LibraryLocationForm(defaults: defaults,
            environment: [StorageLocation.environmentOverrideKey: override])
        form.choose(url: root.url.appendingPathComponent("chosen"))
        #expect(form.displayPath == override)
        #expect(StorageLocation.customPath(defaults: defaults) == root.url.appendingPathComponent("chosen").path)
    }
}

/// Isolated scratch directory per test so validation's create side effects
/// never leak into the real filesystem.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}
