import Foundation
import Testing
@testable import steno_macos

@Suite("Recording diagnostics destination")
struct RecordingDiagnosticsDestinationTests {
    private let userLibrary = URL(filePath: "/Users/someone/Library")

    @Test("writes to the user's log folder by default")
    func usesUserLogFolder() {
        let directory = RecordingDiagnosticsDestination.directory(
            libraryOverride: nil,
            userLibrary: userLibrary
        )

        #expect(directory.path == "/Users/someone/Library/Logs/Steno")
    }

    @Test("stays inside a disposable library instead of the user's log folder")
    func staysInsideIsolatedLibrary() {
        let directory = RecordingDiagnosticsDestination.directory(
            libraryOverride: URL(filePath: "/tmp/steno-test-library"),
            userLibrary: userLibrary
        )

        #expect(directory.path == "/tmp/steno-test-library/diagnostics")
    }
}
