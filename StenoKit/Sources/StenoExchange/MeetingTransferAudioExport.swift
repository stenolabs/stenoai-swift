import AudioToolbox
import Darwin
import Foundation
import StenoAudioEncoding

/// Owns compressed export copies until the archive writer has consumed them.
package final class MeetingTransferAudioExport {
    private let root: URL
    private var session: MeetingTransferPrivateSession?

    package init(root: URL) throws {
        self.root = root
    }

    package func cleanup() throws { try session?.cleanup() }

    package func prepare(
        sourceURL: URL, expected: MeetingTransferPreparedCAFSource
    ) throws -> (url: URL, source: MeetingTransferPreparedCAFSource) {
        // Preserve all already-compressed CAF codecs and multichannel PCM without loss.
        // Small sources cannot amortize CAF's packet-table/header overhead.
        guard expected.formatID == kAudioFormatLinearPCM,
              expected.channelCount <= 2, expected.byteCount > 32_768
        else { return (sourceURL, expected) }
        let fd = open(sourceURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MeetingTransferArchiveWriterError.sourceOpenFailed(sourceURL.lastPathComponent) }
        defer { Darwin.close(fd) }
        func validateOriginal() throws {
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  MeetingTransferFileIdentity(status) == expected.identity
            else { throw MeetingTransferArchiveWriterError.sourceIdentityMismatch(sourceURL.lastPathComponent) }
            guard status.st_size == expected.byteCount else {
                throw MeetingTransferArchiveWriterError.sourceByteCountMismatch(sourceURL.lastPathComponent)
            }
            guard try MeetingTransferDigest.sha256(fileDescriptor: fd, expectedByteCount: expected.byteCount) == expected.byteSHA256 else {
                throw MeetingTransferArchiveWriterError.sourceHashMismatch(sourceURL.lastPathComponent)
            }
        }
        try validateOriginal()
        let session: MeetingTransferPrivateSession
        if let existing = self.session {
            session = existing
        } else {
            session = try MeetingTransferPrivateRoot.prepareAndVerify(at: root).createSession()
            self.session = session
        }
        var volume = statfs()
        let required = UInt64(expected.byteCount) + UInt64(MeetingTransferLimits.minimumFreeSpaceReserveBytes) + 65_536
        guard fstatfs(session.directoryFileDescriptor, &volume) == 0,
              UInt64(volume.f_bavail) * UInt64(volume.f_bsize) >= required else {
            throw MeetingTransferArchiveWriterError.insufficientCapacity
        }
        let name = "audio-\(UUID().uuidString).caf"
        let output = try session.createFile(named: name)
        defer { output.close() }
        let result = try CAFEncoder.encode(source: fd, destination: output.rawValue)
        try validateOriginal()
        let url = session.url.appendingPathComponent(name)
        let (verified, identity) = try session.openVerifiedReadDescriptor(named: name, matching: output.rawValue)
        defer { verified.close() }
        let prepared = try MeetingTransferAudioInspector().prepareCAFSource(at: url)
        guard prepared.identity == identity,
              prepared.formatID == kAudioFormatMPEG4AAC,
              prepared.sampleRate == expected.sampleRate,
              prepared.channelCount == expected.channelCount,
              abs(prepared.duration - Double(result.frameCount) / result.sampleRate) < 1 / result.sampleRate
        else { throw MeetingTransferValidationError.audioMetadataMismatch(name) }
        // An export should not get bigger merely because it was encoded.
        return prepared.byteCount < expected.byteCount ? (url, prepared) : (sourceURL, expected)
    }
}
