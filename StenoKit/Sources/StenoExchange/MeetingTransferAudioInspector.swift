@preconcurrency import AudioToolbox
import CryptoKit
import Darwin
import Foundation
import StenoDomain
import Synchronization

public struct ValidatedMeetingTransferAudio: Sendable {
    public let logicalTrackID: String
    public let kind: MediaAsset.Kind
    public let byteSHA256: String
    public let sampleRate: Double
    public let channelCount: Int
    public let duration: TimeInterval
    private let source: MeetingTransferValidatedAudioSource

    init(
        source: MeetingTransferValidatedAudioSource,
        logicalTrackID: String,
        kind: MediaAsset.Kind,
        byteSHA256: String,
        sampleRate: Double,
        channelCount: Int,
        duration: TimeInterval
    ) {
        self.source = source
        self.logicalTrackID = logicalTrackID
        self.kind = kind
        self.byteSHA256 = byteSHA256
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
    }

    public func leaseSource() throws -> MeetingTransferAudioSourceLease {
        try source.makeLease()
    }

    func closeSource() {
        source.close()
    }

    func revalidateSource() throws {
        try source.revalidateIntegrity()
    }
}

public final class MeetingTransferAudioSourceLease: @unchecked Sendable {
    public let sourceURL: URL
    private let descriptor: MeetingTransferOwnedDescriptor
    private let sessionLease: MeetingTransferSessionUseLease?
    private let source: MeetingTransferValidatedAudioSource
    private let isClosed = Mutex(false)

    fileprivate var fileDescriptor: Int32 { descriptor.rawValue }

    init(
        descriptor: MeetingTransferOwnedDescriptor,
        sessionLease: MeetingTransferSessionUseLease?,
        source: MeetingTransferValidatedAudioSource
    ) {
        self.descriptor = descriptor
        self.sessionLease = sessionLease
        self.source = source
        sourceURL = URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)")
    }

    public func close() {
        let shouldClose = isClosed.withLock { closed -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        descriptor.close()
        source.releaseLease()
        sessionLease?.close()
    }

    deinit {
        close()
    }
}

package struct MeetingTransferCAFInspection: Sendable {
    package let byteCount: Int64
    package let formatID: AudioFormatID
    package let sampleRate: Double
    package let channelCount: Int
    package let duration: TimeInterval
}

package struct MeetingTransferPreparedCAFSource: Sendable {
    package let byteCount: Int64
    package let formatID: AudioFormatID
    package let byteSHA256: String
    package let sampleRate: Double
    package let channelCount: Int
    package let duration: TimeInterval
    let identity: MeetingTransferFileIdentity
}

enum MeetingTransferCAFContainer {
    private static let supportedHeader: [UInt8] = [
        0x63, 0x61, 0x66, 0x66, // caff
        0x00, 0x01,             // CAF version 1
        0x00, 0x00,             // reserved flags
    ]

    static func hasSupportedHeader(fileDescriptor: Int32) -> Bool {
        var header = [UInt8](repeating: 0, count: supportedHeader.count)
        let byteCount = header.count
        var offset = 0
        while offset < byteCount {
            let count = header.withUnsafeMutableBytes { bytes in
                pread(
                    fileDescriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            return false
        }
        return header == supportedHeader
    }
}

final class MeetingTransferValidatedAudioSource: @unchecked Sendable {
    private struct State: Sendable {
        var descriptor: MeetingTransferOwnedDescriptor?
        var isLeased = false
    }

    private let state: Mutex<State>
    private let identity: MeetingTransferFileIdentity
    private let byteCount: Int64
    private let path: String
    private let expectedSHA256: String
    private let session: MeetingTransferPrivateSession?

    init(
        descriptor: MeetingTransferOwnedDescriptor,
        identity: MeetingTransferFileIdentity,
        byteCount: Int64,
        path: String,
        expectedSHA256: String,
        session: MeetingTransferPrivateSession?
    ) {
        state = Mutex(State(descriptor: descriptor, isLeased: false))
        self.identity = identity
        self.byteCount = byteCount
        self.path = path
        self.expectedSHA256 = expectedSHA256
        self.session = session
    }

    func makeLease() throws -> MeetingTransferAudioSourceLease {
        let sessionLease = try session?.acquireLease()
        do {
            let duplicate = try state.withLock { state -> Int32 in
                guard let descriptor = state.descriptor, !state.isLeased else {
                    throw MeetingTransferValidationError.sessionInUse
                }
                try validateContents(of: descriptor.rawValue)
                let value = fcntl(descriptor.rawValue, F_DUPFD_CLOEXEC, 0)
                guard value >= 0 else {
                    throw MeetingTransferValidationError.sessionInUse
                }
                state.isLeased = true
                return value
            }
            var status = stat()
            guard fstat(duplicate, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_size == byteCount,
                  MeetingTransferFileIdentity(status) == identity
            else {
                Darwin.close(duplicate)
                throw MeetingTransferValidationError.stagedFileIdentityMismatch(path)
            }
            return MeetingTransferAudioSourceLease(
                descriptor: MeetingTransferOwnedDescriptor(duplicate),
                sessionLease: sessionLease,
                source: self
            )
        } catch {
            state.withLock { $0.isLeased = false }
            sessionLease?.close()
            throw error
        }
    }

    func revalidateIntegrity() throws {
        let sessionLease = try session?.acquireLease()
        defer { sessionLease?.close() }
        try state.withLock { state in
            guard let descriptor = state.descriptor, !state.isLeased else {
                throw MeetingTransferValidationError.sessionInUse
            }
            var status = stat()
            guard fstat(descriptor.rawValue, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_size == byteCount,
                  MeetingTransferFileIdentity(status) == identity
            else {
                throw MeetingTransferValidationError.stagedFileIdentityMismatch(path)
            }
            try validateContents(of: descriptor.rawValue)
        }
    }

    private func validateContents(of descriptor: Int32) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw MeetingTransferValidationError.stagedFileIdentityMismatch(path)
        }
        var hasher = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: MeetingTransferDigest.fileReadChunkSize)
        while total < byteCount {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(buffer.count), byteCount - total))
            let count: Int
            while true {
                let result = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, wanted)
                }
                if result >= 0 {
                    count = result
                    break
                }
                if errno != EINTR {
                    throw MeetingTransferValidationError.stagedFileIdentityMismatch(path)
                }
            }
            guard count > 0 else {
                throw MeetingTransferValidationError.hashMismatch(path)
            }
            buffer.withUnsafeBytes { bytes in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<count]))
            }
            total += Int64(count)
        }
        var sentinel: UInt8 = 0
        let extra = Darwin.read(descriptor, &sentinel, 1)
        guard extra == 0 else {
            throw MeetingTransferValidationError.hashMismatch(path)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw MeetingTransferValidationError.hashMismatch(path)
        }
    }

    fileprivate func releaseLease() {
        state.withLock { state in
            guard state.isLeased else { return }
            if let descriptor = state.descriptor {
                _ = lseek(descriptor.rawValue, 0, SEEK_SET)
            }
            state.isLeased = false
        }
    }

    func close() {
        let descriptor = state.withLock { state -> MeetingTransferOwnedDescriptor? in
            defer { state.descriptor = nil }
            return state.descriptor
        }
        descriptor?.close()
    }

    deinit {
        close()
    }
}

public struct MeetingTransferAudioInspector: Sendable {
    public init() {}

    package func inspectCAFSource(at sourceURL: URL) throws -> MeetingTransferCAFInspection {
        let source = try Self.openCAFSource(at: sourceURL)
        defer { source.descriptor.close() }
        let values = try Self.inspectAudioValues(
            fileDescriptor: source.descriptor.rawValue,
            logicalTrackID: sourceURL.lastPathComponent
        )
        return MeetingTransferCAFInspection(
            byteCount: source.byteCount,
            formatID: values.formatID,
            sampleRate: values.sampleRate,
            channelCount: values.channelCount,
            duration: values.duration
        )
    }

    package func prepareCAFSource(
        at sourceURL: URL
    ) throws -> MeetingTransferPreparedCAFSource {
        let source = try Self.openCAFSource(at: sourceURL)
        defer { source.descriptor.close() }
        guard source.byteCount > 0,
              source.byteCount <= MeetingTransferLimits.maximumAudioBytes
        else {
            throw MeetingTransferValidationError.unsupportedAudio(
                sourceURL.lastPathComponent
            )
        }
        let values = try Self.inspectAudioValues(
            fileDescriptor: source.descriptor.rawValue,
            logicalTrackID: sourceURL.lastPathComponent
        )
        let digest: String
        do {
            digest = try MeetingTransferDigest.sha256(
                fileDescriptor: source.descriptor.rawValue,
                expectedByteCount: source.byteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MeetingTransferValidationError.unsupportedAudio(
                sourceURL.lastPathComponent
            )
        }
        var finalStatus = stat()
        guard fstat(source.descriptor.rawValue, &finalStatus) == 0,
              finalStatus.st_mode & S_IFMT == S_IFREG,
              Int64(finalStatus.st_size) == source.byteCount,
              MeetingTransferFileIdentity(finalStatus) == source.identity
        else {
            throw MeetingTransferValidationError.unsupportedAudio(
                sourceURL.lastPathComponent
            )
        }
        return MeetingTransferPreparedCAFSource(
            byteCount: source.byteCount,
            formatID: values.formatID,
            byteSHA256: digest,
            sampleRate: values.sampleRate,
            channelCount: values.channelCount,
            duration: values.duration,
            identity: source.identity
        )
    }

    public func inspect(
        sourceURL: URL,
        document: MeetingTransferAudioDocument,
        byteSHA256: String
    ) throws -> ValidatedMeetingTransferAudio {
        let descriptor = open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MeetingTransferValidationError.unsupportedAudio(document.logicalTrackID)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0
        else {
            Darwin.close(descriptor)
            throw MeetingTransferValidationError.unsupportedAudio(document.logicalTrackID)
        }
        let source = MeetingTransferValidatedAudioSource(
            descriptor: MeetingTransferOwnedDescriptor(descriptor),
            identity: MeetingTransferFileIdentity(status),
            byteCount: Int64(status.st_size),
            path: sourceURL.lastPathComponent,
            expectedSHA256: byteSHA256,
            session: nil
        )
        return try inspect(source: source, document: document, byteSHA256: byteSHA256)
    }

    func inspect(
        source: MeetingTransferValidatedAudioSource,
        document: MeetingTransferAudioDocument,
        byteSHA256: String
    ) throws -> ValidatedMeetingTransferAudio {
        let sourceLease = try source.makeLease()
        defer { sourceLease.close() }
        guard MeetingTransferCAFContainer.hasSupportedHeader(
            fileDescriptor: sourceLease.fileDescriptor
        ) else {
            throw MeetingTransferValidationError.unsupportedAudio(document.logicalTrackID)
        }
        let values = try Self.inspectAudioValues(
            fileDescriptor: sourceLease.fileDescriptor,
            logicalTrackID: document.logicalTrackID
        )
        let sampleRate = values.sampleRate
        let channelCount = values.channelCount
        let duration = values.duration

        let sampleRateTolerance = max(0.000_001, sampleRate * 0.000_001)
        let durationTolerance = max(0.001, 1 / sampleRate)
        guard document.sampleRate.isFinite,
              document.sampleRate > 0,
              abs(document.sampleRate - sampleRate) <= sampleRateTolerance,
              document.channelCount == channelCount,
              document.duration.isFinite,
              document.duration > 0,
              abs(document.duration - duration) <= durationTolerance
        else {
            throw MeetingTransferValidationError.audioMetadataMismatch(document.logicalTrackID)
        }

        return ValidatedMeetingTransferAudio(
            source: source,
            logicalTrackID: document.logicalTrackID,
            kind: document.kind,
            byteSHA256: byteSHA256,
            sampleRate: sampleRate,
            channelCount: channelCount,
            duration: duration
        )
    }

    private static func openCAFSource(
        at sourceURL: URL
    ) throws -> OpenedCAFSource {
        let descriptor = open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MeetingTransferValidationError.unsupportedAudio(
                sourceURL.lastPathComponent
            )
        }
        let ownedDescriptor = MeetingTransferOwnedDescriptor(descriptor)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              MeetingTransferCAFContainer.hasSupportedHeader(fileDescriptor: descriptor)
        else {
            ownedDescriptor.close()
            throw MeetingTransferValidationError.unsupportedAudio(
                sourceURL.lastPathComponent
            )
        }
        return OpenedCAFSource(
            descriptor: ownedDescriptor,
            identity: MeetingTransferFileIdentity(status),
            byteCount: Int64(status.st_size)
        )
    }

    private static func inspectAudioValues(
        fileDescriptor: Int32,
        logicalTrackID: String
    ) throws -> (sampleRate: Double, channelCount: Int, duration: TimeInterval, formatID: AudioFormatID) {
        var descriptorStatus = stat()
        guard fstat(fileDescriptor, &descriptorStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_size >= 0
        else {
            throw MeetingTransferValidationError.unsupportedAudio(logicalTrackID)
        }

        let context = MeetingTransferAudioFileContext(
            fileDescriptor: fileDescriptor,
            byteCount: Int64(descriptorStatus.st_size)
        )
        return try withExtendedLifetime(context) {
            var audioFile: AudioFileID?
            let openStatus = AudioFileOpenWithCallbacks(
                Unmanaged.passUnretained(context).toOpaque(),
                meetingTransferAudioRead,
                nil,
                meetingTransferAudioSize,
                nil,
                kAudioFileCAFType,
                &audioFile
            )
            guard openStatus == noErr, let audioFile else {
                if let audioFile { _ = AudioFileClose(audioFile) }
                throw MeetingTransferValidationError.unsupportedAudio(logicalTrackID)
            }

            var extendedFile: ExtAudioFileRef?
            let wrapStatus = ExtAudioFileWrapAudioFileID(audioFile, false, &extendedFile)
            guard wrapStatus == noErr, let extendedFile else {
                if let extendedFile { _ = ExtAudioFileDispose(extendedFile) }
                _ = AudioFileClose(audioFile)
                throw MeetingTransferValidationError.unsupportedAudio(logicalTrackID)
            }

            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let formatStatus = ExtAudioFileGetProperty(
                extendedFile,
                kExtAudioFileProperty_FileDataFormat,
                &formatSize,
                &format
            )
            var frameCount: Int64 = 0
            var frameCountSize = UInt32(MemoryLayout<Int64>.size)
            let frameCountStatus = ExtAudioFileGetProperty(
                extendedFile,
                kExtAudioFileProperty_FileLengthFrames,
                &frameCountSize,
                &frameCount
            )
            let disposeStatus = ExtAudioFileDispose(extendedFile)
            let closeStatus = AudioFileClose(audioFile)

            guard formatStatus == noErr,
                  frameCountStatus == noErr,
                  disposeStatus == noErr,
                  closeStatus == noErr,
                  formatSize == MemoryLayout<AudioStreamBasicDescription>.size,
                  frameCountSize == MemoryLayout<Int64>.size
            else {
                throw MeetingTransferValidationError.unsupportedAudio(logicalTrackID)
            }

            let sampleRate = format.mSampleRate
            let channelCount = Int(format.mChannelsPerFrame)
            guard frameCount > 0 else {
                throw MeetingTransferValidationError.emptyAudio(logicalTrackID)
            }
            guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
                throw MeetingTransferValidationError.unsupportedAudio(logicalTrackID)
            }
            let duration = Double(frameCount) / sampleRate
            guard duration.isFinite, duration > 0 else {
                throw MeetingTransferValidationError.emptyAudio(logicalTrackID)
            }
            return (sampleRate, channelCount, duration, format.mFormatID)
        }
    }
}

private final class MeetingTransferAudioFileContext {
    let fileDescriptor: Int32
    let byteCount: Int64

    init(fileDescriptor: Int32, byteCount: Int64) {
        self.fileDescriptor = fileDescriptor
        self.byteCount = byteCount
    }
}

private let meetingTransferAudioRead: AudioFile_ReadProc = {
    clientData,
    position,
    requestedByteCount,
    buffer,
    actualByteCount in
    let context = Unmanaged<MeetingTransferAudioFileContext>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    actualByteCount.pointee = 0
    guard position >= 0, position <= context.byteCount else {
        return kAudioFileInvalidFileError
    }

    let availableByteCount = context.byteCount - position
    let byteCount = Int(min(Int64(requestedByteCount), availableByteCount))
    var totalRead = 0
    while totalRead < byteCount {
        let result = pread(
            context.fileDescriptor,
            buffer.advanced(by: totalRead),
            byteCount - totalRead,
            off_t(position + Int64(totalRead))
        )
        if result > 0 {
            totalRead += result
            continue
        }
        if result == 0 { break }
        if errno == EINTR { continue }
        return OSStatus(errno)
    }
    actualByteCount.pointee = UInt32(totalRead)
    return noErr
}

private let meetingTransferAudioSize: AudioFile_GetSizeProc = { clientData in
    Unmanaged<MeetingTransferAudioFileContext>
        .fromOpaque(clientData)
        .takeUnretainedValue()
        .byteCount
}

private struct OpenedCAFSource {
    let descriptor: MeetingTransferOwnedDescriptor
    let identity: MeetingTransferFileIdentity
    let byteCount: Int64
}
