import Foundation
import Testing
@testable import StenoAudioCore

@Suite("Recording diagnostics log")
struct RecordingDiagnosticsLogTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("steno-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func lines(in url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test("appends one readable JSON line per event")
    func appendsOneLinePerEvent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RecordingDiagnosticsFileLog(directory: directory)

        log.record(RecordingDiagnosticEvent(
            name: "microphone-not-stable",
            details: ["uid": "camera-uid", "trace": "0 ms absent, 200 ms id=100"]
        ))
        log.record(RecordingDiagnosticEvent(name: "recording-start-failed"))
        log.flush()

        let written = try lines(in: log.fileURL)
        #expect(written.count == 2)

        let first = try #require(
            JSONSerialization.jsonObject(
                with: Data(written[0].utf8)
            ) as? [String: Any]
        )
        #expect(first["event"] as? String == "microphone-not-stable")
        #expect((first["details"] as? [String: String])?["uid"] == "camera-uid")
        #expect(first["timestamp"] is String)

        let second = try #require(
            JSONSerialization.jsonObject(
                with: Data(written[1].utf8)
            ) as? [String: Any]
        )
        #expect(second["event"] as? String == "recording-start-failed")
    }

    @Test("rotates instead of growing past its size limit")
    func rotatesRatherThanGrowing() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RecordingDiagnosticsFileLog(
            directory: directory,
            maximumBytes: 400
        )

        for index in 0..<40 {
            log.record(RecordingDiagnosticEvent(
                name: "microphone-not-stable",
                details: ["attempt": "\(index)"]
            ))
        }

        log.flush()

        let size = try FileManager.default
            .attributesOfItem(atPath: log.fileURL.path)[.size] as? Int
        #expect((size ?? .max) <= 400)
        #expect(FileManager.default.fileExists(atPath: log.rotatedFileURL.path))
        // The newest attempt must survive rotation, otherwise the log drops
        // exactly the failure the user just hit.
        let written = try lines(in: log.fileURL)
        #expect(written.last?.contains("\"attempt\":\"39\"") == true)
    }
}
