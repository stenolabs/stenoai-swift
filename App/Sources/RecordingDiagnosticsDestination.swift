import Foundation
import StenoAudioCore

/// Decides where recording diagnostics are written.
///
/// A failed start is shown once as a notice and is then gone, and the unified
/// system log is rotated out long before anyone can look at it. The file this
/// points at is what remains to explain a failure the next day. It follows the
/// same rule as the library itself: a disposable library keeps its diagnostics
/// beside it, so a test run can never write into the real log folder.
enum RecordingDiagnosticsDestination {
    static func directory(libraryOverride: URL?, userLibrary: URL) -> URL {
        if let libraryOverride {
            return libraryOverride.appendingPathComponent(
                "diagnostics",
                isDirectory: true
            )
        }
        return userLibrary
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Steno", isDirectory: true)
    }

    static func standard() -> any RecordingDiagnosticsRecording {
        let override = ProcessInfo.processInfo
            .environment["STENO_LIBRARY_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let userLibrary = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else {
            return NullRecordingDiagnostics()
        }
        return RecordingDiagnosticsFileLog(
            directory: directory(
                libraryOverride: override,
                userLibrary: userLibrary
            )
        )
    }
}
