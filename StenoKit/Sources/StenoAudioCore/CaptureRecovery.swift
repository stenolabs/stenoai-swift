@preconcurrency import AVFAudio
import Foundation
import StenoDomain
import StenoLibrary

/// Adoptiert nach einem harten Absturz die gestrandeten Capture-Dateien
/// unterbrochener Meetings: registriert sie als Originalspuren und reiht
/// den Finalisierungslauf ein. Läuft nach dem RecoverySweep (der Meetings
/// von `recording` auf `interrupted` setzt, aber ohne Spuren keinen Job
/// einreiht).
public enum CaptureRecovery {
    public struct AdoptedMeeting: Equatable, Sendable {
        public let meetingID: MeetingID
        public let adoptedTracks: [AudioTrack]
    }

    /// Why a capture file was left where it is instead of becoming a track.
    public enum AdoptionRefusal: Error, Equatable, Sendable {
        /// The file carries a track name but never received a frame. That is
        /// what an abandoned track leaves behind when setting it aside failed,
        /// and adopting it would hand the user a recording that never existed.
        case captureFileWithoutAudio
    }

    public struct Failure: Sendable {
        public enum Stage: String, Sendable {
            case meetingMetadata
            case captureDirectory
            case captureFile
            case mediaRegistration
            case captureCleanup
            case jobScheduling
        }

        public let meetingID: MeetingID
        public let fileName: String?
        public let stage: Stage
        public let error: any Error

        public init(
            meetingID: MeetingID,
            fileName: String? = nil,
            stage: Stage,
            error: any Error
        ) {
            self.meetingID = meetingID
            self.fileName = fileName
            self.stage = stage
            self.error = error
        }
    }

    public struct Report: Sendable {
        public let adoptedMeetings: [AdoptedMeeting]
        public let failures: [Failure]

        public init(
            adoptedMeetings: [AdoptedMeeting],
            failures: [Failure]
        ) {
            self.adoptedMeetings = adoptedMeetings
            self.failures = failures
        }
    }

    private static func pendingURL(layout: LibraryLayout, meetingID: MeetingID) -> URL {
        layout.captureDirectory(meetingID).appendingPathComponent(".recovery-pending")
    }

    /// Call only after a follow-up job has been persisted successfully.
    public static func completeFinalization(layout: LibraryLayout, meetingID: MeetingID) throws {
        let url = pendingURL(layout: layout, meetingID: meetingID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    public static func run(
        library: Library,
        jobStore: JobStore,
        onlyMeetingID: MeetingID? = nil,
        scheduleJobs: Bool = true
    ) async throws -> Report {
        var adopted: [AdoptedMeeting] = []
        var failures: [Failure] = []
        for meetingID in try meetingIDs(in: library.layout) {
            if let onlyMeetingID, meetingID != onlyMeetingID { continue }
            let meeting: Meeting
            do {
                meeting = try await library.loadMeeting(meetingID)
            } catch {
                failures.append(Failure(
                    meetingID: meetingID,
                    stage: .meetingMetadata,
                    error: error
                ))
                continue
            }
            guard meeting.status == .interrupted else { continue }

            let captureDirectory = library.layout.captureDirectory(meeting.id)
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: captureDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                failures.append(Failure(
                    meetingID: meeting.id,
                    stage: .captureDirectory,
                    error: error
                ))
                continue
            }
            let pending = pendingURL(layout: library.layout, meetingID: meeting.id)
            guard !files.isEmpty || FileManager.default.fileExists(atPath: pending.path) else { continue }

            var tracks: [AudioTrack] = []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let track = trackFromCaptureFileName(file.lastPathComponent) else {
                    continue
                }
                // Ein Prefix, den AVAudioFile nicht mehr lesen kann, wird
                // liegengelassen und im Ergebnis gemeldet, nie gelöscht.
                let audioFile: AVAudioFile
                do {
                    audioFile = try AVAudioFile(forReading: file)
                } catch {
                    failures.append(Failure(
                        meetingID: meeting.id,
                        fileName: file.lastPathComponent,
                        stage: .captureFile,
                        error: error
                    ))
                    continue
                }
                let sampleRate = audioFile.fileFormat.sampleRate
                guard audioFile.length > 0 else {
                    // Reported, never deleted: the file stays for inspection,
                    // but an empty track is not a recording.
                    failures.append(Failure(
                        meetingID: meeting.id,
                        fileName: file.lastPathComponent,
                        stage: .captureFile,
                        error: AdoptionRefusal.captureFileWithoutAudio
                    ))
                    continue
                }
                let duration = sampleRate > 0
                    ? Double(audioFile.length) / sampleRate
                    : 0
                do {
                    // Persist the need to schedule before moving the last CAF.
                    // A crash after adoption must not strand an unprocessed asset.
                    try AtomicFile.write(Data("pending".utf8), to: pending)
                    _ = try await library.registerCapturedMediaAsset(
                        for: meeting.id,
                        sourceURL: file,
                        kind: track == .microphone ? .micTrack : .systemTrack,
                        sampleRate: sampleRate,
                        duration: duration
                    )
                } catch {
                    failures.append(Failure(
                        meetingID: meeting.id,
                        fileName: file.lastPathComponent,
                        stage: .mediaRegistration,
                        error: error
                    ))
                    continue
                }
                tracks.append(track)
            }
            guard !tracks.isEmpty || FileManager.default.fileExists(atPath: pending.path) else { continue }

            if !tracks.isEmpty { adopted.append(AdoptedMeeting(meetingID: meeting.id, adoptedTracks: tracks)) }
            // Never render a partial view of the recovered capture set.
            guard scheduleJobs, !failures.contains(where: {
                $0.meetingID == meeting.id && !($0.error is AdoptionRefusal)
            }) else { continue }

            // Ein früherer Lauf kann bereits als failed dastehen ("has no
            // media assets"); der wird reaktiviert statt dupliziert.
            do {
                let existing = try await jobStore.list().filter {
                    $0.kind == .finalASR && $0.meetingID == meeting.id
                        && $0.processingGenerationID == meeting.processingGenerationID
                }
                if let failed = existing.first(where: { $0.status == .failed }) {
                    _ = try await jobStore.transition(failed.id, to: .queued)
                } else if !existing.contains(where: {
                    $0.status == .queued || $0.status == .running
                }) {
                    try await jobStore.enqueue(
                        Job.finalASR(for: meeting)
                    )
                }
                try completeFinalization(layout: library.layout, meetingID: meeting.id)
            } catch {
                failures.append(Failure(
                    meetingID: meeting.id,
                    stage: .jobScheduling,
                    error: error
                ))
            }

        }
        return Report(adoptedMeetings: adopted, failures: failures)
    }

    private static func meetingIDs(in layout: LibraryLayout) throws -> [MeetingID] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: layout.meetingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let rawValue = UUID(uuidString: directory.lastPathComponent) else {
                return nil
            }
            return MeetingID(rawValue: rawValue)
        }.sorted()
    }

    /// Capture-Dateien heißen `<meetingID>-<track>-<uuid>.caf`.
    static func trackFromCaptureFileName(_ name: String) -> AudioTrack? {
        // Only a capture file is a track. A file set aside because its track
        // was abandoned during start keeps its name but loses the `.caf`
        // ending, and must never be adopted as a recording.
        guard name.hasSuffix(".caf") else { return nil }
        return AudioTrack.allCases.first { name.contains("-\($0.rawValue)-") }
    }
}
