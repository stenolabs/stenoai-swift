import Foundation

/// A content-safe note about one step of starting or stopping a recording:
/// never audio, never meeting text, only what the audio stack reported.
public struct RecordingDiagnosticEvent: Equatable, Sendable {
    public let name: String
    public let details: [String: String]

    public init(name: String, details: [String: String] = [:]) {
        self.name = name
        self.details = details
    }
}

public protocol RecordingDiagnosticsRecording: Sendable {
    func record(_ event: RecordingDiagnosticEvent)
    /// Makes sure everything recorded so far has reached its destination.
    ///
    /// Deliberately without a default implementation in an extension: a
    /// conformance in another module that inherited such a default crashed the
    /// process with SIGILL when the call came through the existential. Every
    /// destination states for itself what flushing means.
    func flush()
}

/// Discards every event. The default wherever a caller has no log configured,
/// so diagnostics can never be the reason a recording fails to start.
public struct NullRecordingDiagnostics: RecordingDiagnosticsRecording {
    public init() {}
    public func record(_ event: RecordingDiagnosticEvent) {}
    public func flush() {}
}

/// Appends one JSON line per event to a file that survives the app.
///
/// A failed recording start is reported once as a notice on screen and is then
/// gone; the unified system log is rotated out long before anyone looks. This
/// log exists so the next failure can still be explained tomorrow.
///
/// Recording it must never cost a recording, so `record` only enqueues: the
/// file work happens on a serial background queue and never blocks the caller,
/// which is the main actor for app events and the `MicRecorder` actor during
/// start. The trade is that a hard crash can lose the last line, which is
/// acceptable for a log that explains failures the app survives.
public final class RecordingDiagnosticsFileLog:
    RecordingDiagnosticsRecording, @unchecked Sendable {
    public let fileURL: URL
    public let rotatedFileURL: URL

    private let maximumBytes: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(
        label: "org.steno.recording-diagnostics",
        qos: .utility
    )
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(
        directory: URL,
        fileName: String = "recording-diagnostics.jsonl",
        maximumBytes: Int = 1_000_000,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        fileURL = directory.appendingPathComponent(fileName)
        rotatedFileURL = directory.appendingPathComponent("\(fileName).1")
        self.maximumBytes = maximumBytes
        self.now = now
    }

    public func record(_ event: RecordingDiagnosticEvent) {
        // Stamped here so the order in the file matches the order of events,
        // not the order the queue happens to drain in.
        let timestamp = now()
        queue.async { [self] in
            guard let line = line(for: event, at: timestamp) else { return }
            // A diagnostics failure must stay invisible to the caller: it may
            // not turn a recoverable audio problem into a second one.
            try? append(line)
        }
    }

    /// Waits until everything recorded so far has reached the file. For the end
    /// of a process, and for readers that need the file to be complete.
    public func flush() {
        queue.sync {}
    }

    private func line(
        for event: RecordingDiagnosticEvent,
        at timestamp: Date
    ) -> Data? {
        let payload: [String: Any] = [
            "timestamp": timestampFormatter.string(from: timestamp),
            "event": event.name,
            "details": event.details,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return data + Data("\n".utf8)
    }

    private func append(_ line: Data) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        if currentSize() + line.count > maximumBytes {
            try? manager.removeItem(at: rotatedFileURL)
            try? manager.moveItem(at: fileURL, to: rotatedFileURL)
        }
        guard manager.fileExists(atPath: fileURL.path) else {
            try line.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func currentSize() -> Int {
        let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int
        return size.flatMap { $0 } ?? 0
    }
}
