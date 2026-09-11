import AppleArchive
import Darwin
import Foundation
import StenoDomain
import Synchronization
import Testing
@testable import StenoExchange

@Suite("Meeting transfer archive security")
struct MeetingTransferArchiveSecurityTests {

    @Test("validation rejects a directory and an outer archive symlink")
    func rejectsNonRegularOuterInputs() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("directory.stenomeeting", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        await expectValidationError(
            .archiveIsNotRegularFile,
            at: directory,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-directory")
        )

        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let target = base.appendingPathComponent("target.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: target)
        let link = base.appendingPathComponent("link.stenomeeting")
        guard symlink(target.path, link.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        await expectValidationError(
            .archiveIsSymbolicLink,
            at: link,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-link")
        )
    }

    @Test("validation rejects an outer FIFO promptly without opening a writer")
    func rejectsOuterFIFONonblocking() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fifo = base.appendingPathComponent("pipe.stenomeeting")
        guard mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let writerOpened = Mutex(false)
        let delayedUnblocker = Task.detached {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            writerOpened.withLock { $0 = true }
            _ = Darwin.close(descriptor)
        }
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-fifo")
        let clock = ContinuousClock()
        let started = clock.now

        await expectValidationError(
            .archiveIsNotRegularFile,
            at: fifo,
            validationRoot: validationRoot
        )
        let elapsed = started.duration(to: clock.now)
        delayedUnblocker.cancel()
        await delayedUnblocker.value

        #expect(elapsed < .milliseconds(250))
        #expect(!writerOpened.withLock { $0 })
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("validation rejects a stream that is not raw AppleArchive")
    func rejectsCompressedArchive() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let raw = base.appendingPathComponent("raw.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: raw)
        let compressed = base.appendingPathComponent("compressed.stenomeeting")
        try writeTransferCompressedArchive(rawURL: raw, to: compressed)

        await expectValidationError(
            .notRawAppleArchive,
            at: compressed,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
    }

    @Test("validation rejects absolute and parent-traversal paths")
    func rejectsUnsafePaths() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        for path in ["/tmp/notes.md", "../notes.md", "audio/../notes.md"] {
            let archive = base.appendingPathComponent(UUID().uuidString)
            try writeTransferRawArchive(
                [manifest, .regular(path: path, data: Data())],
                to: archive
            )
            await expectValidationError(
                .invalidEntryPath(path),
                at: archive,
                validationRoot: makeTransferTestRoot(under: base, name: "validation-paths")
            )
        }
    }

    @Test("validation rejects every nonregular entry type")
    func rejectsUnsupportedEntryTypes() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        let types: [ArchiveHeader.EntryType] = [
            .directory,
            .link,
            .fifo,
            .socket,
            .characterSpecial,
            .blockSpecial,
            .metadata,
        ]
        for type in types {
            let archive = base.appendingPathComponent("type-\(type.rawValue).stenomeeting")
            try writeTransferRawArchive(
                [manifest, .entry(type: type, path: "notes.md")],
                to: archive
            )
            await expectValidationError(
                .unsupportedEntryType("notes.md"),
                at: archive,
                validationRoot: makeTransferTestRoot(under: base, name: "validation-types")
            )
        }
    }

    @Test("validation rejects hardlink and unknown header fields")
    func rejectsUnallowlistedHeaderFields() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        for key in ["HLC", "XYZ"] {
            let archive = base.appendingPathComponent("field-\(key).stenomeeting")
            try writeTransferRawArchive(
                [manifest, .regular(
                    path: "notes.md",
                    data: Data(),
                    extraFields: [.uint(key, 1)]
                )],
                to: archive
            )
            await expectValidationError(
                .unsupportedHeaderField(key),
                at: archive,
                validationRoot: makeTransferTestRoot(under: base, name: "validation-fields")
            )
        }
    }

    @Test("validation rejects duplicate known fields and wrong field types")
    func rejectsMalformedRequiredFields() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        let duplicateURL = base.appendingPathComponent("duplicate.stenomeeting")
        try writeTransferRawArchive(
            [manifest, .regular(
                path: "notes.md",
                data: Data(),
                extraFields: [.uint("SIZ", 0)]
            )],
            to: duplicateURL
        )
        await expectValidationError(
            .duplicateHeaderField("SIZ"),
            at: duplicateURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-duplicate")
        )

        let wrongTypeURL = base.appendingPathComponent("wrong-type.stenomeeting")
        let wrongType = TransferTestArchiveEntry(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", "notes.md"),
                .string("SIZ", "0"),
                .blob("DAT", 0),
            ],
            blobs: [Data()]
        )
        try writeTransferRawArchive([manifest, wrongType], to: wrongTypeURL)
        await expectValidationError(
            .invalidHeaderFieldType("SIZ"),
            at: wrongTypeURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-type")
        )
    }

    @Test("validation rejects nonzero DAT offset and DAT SIZ disagreement")
    func rejectsInvalidBlobLayout() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        let offsetURL = base.appendingPathComponent("offset.stenomeeting")
        let offsetEntry = TransferTestArchiveEntry(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", "notes.md"),
                .uint("SIZ", 3),
                .blob("DAT", 1),
                .blob("DAT", 3),
            ],
            blobs: [Data([0]), Data([1, 2, 3])]
        )
        try writeTransferRawArchive([manifest, offsetEntry], to: offsetURL)
        await expectValidationError(
            .invalidDataOffset("notes.md"),
            at: offsetURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-offset")
        )

        let mismatchURL = base.appendingPathComponent("mismatch.stenomeeting")
        let mismatchEntry = TransferTestArchiveEntry(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", "notes.md"),
                .uint("SIZ", 3),
                .blob("DAT", 4),
            ],
            blobs: [Data([1, 2, 3, 4])]
        )
        try writeTransferRawArchive([manifest, mismatchEntry], to: mismatchURL)
        await expectValidationError(
            .sizeMismatch("notes.md"),
            at: mismatchURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-mismatch")
        )
    }

    @Test("validation rejects unrepresentable sizes and oversized logical files before data reads")
    func rejectsUnsafeDeclaredSizes() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        let overflowURL = base.appendingPathComponent("overflow.stenomeeting")
        let overflow = TransferTestArchiveEntry(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", "notes.md"),
                .uint("SIZ", UInt64.max),
                .blob("DAT", 0),
            ],
            blobs: []
        )
        try writeTransferRawArchive([manifest, overflow], to: overflowURL)
        await expectValidationError(
            .sizeMismatch("notes.md"),
            at: overflowURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-overflow")
        )

        // AppleArchive.append traps for an unrepresentable blob size. Build
        // that malformed field as raw bytes to exercise the reader instead.
        var rawOverflow = transferRawArchiveData([overflow])
        let dataField = try #require(rawOverflow.range(of: Data([0x44, 0x41, 0x54, 0x41, 0, 0])))
        rawOverflow.replaceSubrange(dataField, with: Data([0x44, 0x41, 0x54, 0x43] + Array(repeating: UInt8.max, count: 8)))
        let headerSize = UInt16(rawOverflow.count)
        rawOverflow[4] = UInt8(truncatingIfNeeded: headerSize)
        rawOverflow[5] = UInt8(truncatingIfNeeded: headerSize >> 8)
        let rawOverflowURL = base.appendingPathComponent("raw-overflow.stenomeeting")
        try writeTransferRawArchiveBytes(
            transferRawArchiveData([manifest]) + rawOverflow,
            to: rawOverflowURL
        )
        await expectValidationError(
            .trailingGarbage,
            at: rawOverflowURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-raw-overflow")
        )

        let largeURL = base.appendingPathComponent("large-logical.stenomeeting")
        let largeSize = UInt64(MeetingTransferLimits.maximumNotesBytes + 1)
        let large = TransferTestArchiveEntry(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", "notes.md"),
                .uint("SIZ", largeSize),
                .blob("DAT", largeSize),
            ],
            blobs: []
        )
        try writeTransferRawArchive([manifest, large], to: largeURL)
        await expectValidationError(
            .entryTooLarge("notes.md"),
            at: largeURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-large")
        )
    }

    @Test("validation rejects truncated data and trailing garbage")
    func rejectsIncompleteOrTrailingBytes() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifest = fixture.archiveEntries[0]
        let note = Data("abc".utf8)
        let truncatedURL = base.appendingPathComponent("truncated.stenomeeting")
        let truncated = TransferTestArchiveEntry(
            fields: [
                .uint("TYP", UInt64(ArchiveHeader.EntryType.regularFile.rawValue)),
                .string("PAT", "notes.md"),
                .uint("SIZ", UInt64(note.count)),
                .blob("DAT", UInt64(note.count)),
            ],
            blobs: [Data(note.dropLast())]
        )
        try writeTransferRawArchive([manifest, truncated], to: truncatedURL)
        await expectValidationError(
            .truncatedData("notes.md"),
            at: truncatedURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-truncated")
        )

        let trailingURL = base.appendingPathComponent("trailing.stenomeeting")
        try writeTransferRawArchive(
            fixture.archiveEntries,
            to: trailingURL,
            trailingBytes: Data([0xde, 0xad, 0xbe, 0xef])
        )
        await expectValidationError(
            .trailingGarbage,
            at: trailingURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-trailing")
        )
    }

    @Test("raw preflight rejects independently byte-mutated AA01 framing")
    func rejectsManuallyMutatedRawFraming() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        var valid = Data([
            0x41, 0x41, 0x30, 0x31, 0x29, 0x00, // AA01 and 41-byte header length
            0x54, 0x59, 0x50, 0x31, 0x46,       // TYP uint regular-file
            0x50, 0x41, 0x54, 0x50, 0x0d, 0x00, // PAT string, 13 bytes
        ])
        valid.append(Data("manifest.json".utf8))
        valid.append(contentsOf: [
            0x53, 0x49, 0x5a, 0x31, 0x02,       // SIZ uint 2
            0x44, 0x41, 0x54, 0x41, 0x02, 0x00, // DAT blob, size 2, offset 0
            0x7b, 0x7d,                         // payload "{}"
        ])

        var badHeaderLength = valid
        badHeaderLength[4] = 5
        badHeaderLength[5] = 0

        var truncatedHeaderLength = valid
        truncatedHeaderLength[4] = 0xff
        truncatedHeaderLength[5] = 0xff

        var malformedFieldEncoding = valid
        let encodedPathField = Data("PATP".utf8)
        let pathFieldRange = try #require(malformedFieldEncoding.range(of: encodedPathField))
        malformedFieldEncoding[pathFieldRange.index(before: pathFieldRange.upperBound)] = 0xff

        var extraBytes = valid
        extraBytes.append(contentsOf: [0xde, 0xad, 0xbe, 0xef])

        let mutations: [(name: String, bytes: Data)] = [
            ("bad-header-length", badHeaderLength),
            ("truncated-header-length", truncatedHeaderLength),
            ("malformed-field-encoding", malformedFieldEncoding),
            ("extra-bytes", extraBytes),
        ]
        for mutation in mutations {
            let archive = base.appendingPathComponent("\(mutation.name).stenomeeting")
            try writeTransferRawArchiveBytes(mutation.bytes, to: archive)
            let validationRoot = makeTransferTestRoot(
                under: base,
                name: "validation-\(mutation.name)"
            )

            await expectValidationError(
                .trailingGarbage,
                at: archive,
                validationRoot: validationRoot
            )
            #expect(try transferDirectoryContents(validationRoot).isEmpty)
        }
    }

    @Test("raw preflight and decodeStream header results cannot diverge")
    func preflightDecoderDifferentialIsRejected() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(
            content: makeTransferTextContent(notes: "original", transcript: nil)
        )
        let archiveBytes = transferRawArchiveData(fixture.archiveEntries)
        let originalPath = Data("notes.md".utf8)
        let pathRange = try #require(archiveBytes.range(of: originalPath, options: .backwards))
        let archive = base.appendingPathComponent("differential.stenomeeting")
        try writeTransferRawArchiveBytes(archiveBytes, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-differential")
        let changedPath = Data("NOTES.MD".utf8)
        let reader = MeetingTransferArchiveReader(validationCheckpoint: { checkpoint in
            guard case let .afterRawPreflight(fileDescriptor) = checkpoint else { return }
            let written = changedPath.withUnsafeBytes { bytes in
                pwrite(
                    fileDescriptor,
                    bytes.baseAddress,
                    bytes.count,
                    off_t(pathRange.lowerBound)
                )
            }
            guard written == changedPath.count else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        })

        await expectValidationError(
            .parserDifferential(3),
            at: archive,
            validationRoot: validationRoot,
            reader: reader
        )
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("validation rejects Unicode normalization and case collisions")
    func rejectsPathCollisions() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let textFixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let caseURL = base.appendingPathComponent("case.stenomeeting")
        let notes = textFixture.payloadEntries.first { $0.path == "notes.md" }!.data
        try writeTransferRawArchive(
            [
                textFixture.archiveEntries[0],
                .regular(path: "notes.md", data: notes),
                .regular(path: "NOTES.MD", data: notes),
            ],
            to: caseURL
        )
        await expectValidationError(
            .casePathCollision("NOTES.MD"),
            at: caseURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-case")
        )

        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL)
        let audioDocument = try await makeTransferAudioDocument(
            logicalTrackID: "track",
            kind: .micTrack,
            sourceURL: audioURL
        )
        let audioContent = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [audioDocument]
        )
        let audioFixture = try await makeTransferPackageFixture(
            content: audioContent,
            audioSources: ["track": audioURL]
        )
        let canonical = audioFixture.payloadEntries.first {
            $0.path == "audio/track-1.caf"
        }!.data
        let unicodeURL = base.appendingPathComponent("unicode.stenomeeting")
        try writeTransferRawArchive(
            [
                audioFixture.archiveEntries[0],
                .regular(path: "audio/track-1.caf", data: canonical),
                .regular(path: "audio/track-１.caf", data: canonical),
            ],
            to: unicodeURL
        )
        await expectValidationError(
            .unicodePathCollision("audio/track-１.caf"),
            at: unicodeURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-unicode")
        )
    }

    @Test("validation rejects extra missing duplicate-manifest and missing-manifest files")
    func rejectsIncompleteArchiveAllowlist() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())

        let extraURL = base.appendingPathComponent("extra.stenomeeting")
        try writeTransferRawArchive(
            fixture.archiveEntries + [.regular(path: "audio/track-1.caf", data: Data([1]))],
            to: extraURL
        )
        await expectValidationError(
            .extraFile("audio/track-1.caf"),
            at: extraURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-extra")
        )

        let missingURL = base.appendingPathComponent("missing.stenomeeting")
        try writeTransferRawArchive(
            fixture.archiveEntries.filter { entry in
                !entry.fields.contains {
                    if case .string("PAT", "notes.md") = $0 { return true }
                    return false
                }
            },
            to: missingURL
        )
        await expectValidationError(
            .missingFile("notes.md"),
            at: missingURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-missing")
        )

        let duplicateManifestURL = base.appendingPathComponent("duplicate-manifest.stenomeeting")
        try writeTransferRawArchive(
            [fixture.archiveEntries[0], fixture.archiveEntries[0]],
            to: duplicateManifestURL
        )
        await expectValidationError(
            .duplicateArchiveEntryPath("manifest.json"),
            at: duplicateManifestURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-duplicate-manifest")
        )

        let missingManifestURL = base.appendingPathComponent("missing-manifest.stenomeeting")
        try writeTransferRawArchive(
            Array(fixture.archiveEntries.dropFirst()),
            to: missingManifestURL
        )
        await expectValidationError(
            .missingManifest,
            at: missingManifestURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-no-manifest")
        )
    }

    @Test("validation rejects unknown format major and capability")
    func rejectsUnknownManifestSchema() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())

        let majorData = try transferTestJSON(from: fixture.manifestData) {
            $0["formatMajor"] = 2
        }
        let majorURL = base.appendingPathComponent("major.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries(manifestData: majorData), to: majorURL)
        await expectValidationError(
            .unsupportedFormatMajor(2),
            at: majorURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-major")
        )

        let capabilityData = try transferTestJSON(from: fixture.manifestData) {
            $0["capabilities"] = ["notes", "transcript", "unknown"]
        }
        let capabilityURL = base.appendingPathComponent("capability.stenomeeting")
        try writeTransferRawArchive(
            fixture.archiveEntries(manifestData: capabilityData),
            to: capabilityURL
        )
        await expectValidationError(
            .invalidManifest,
            at: capabilityURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-capability")
        )
    }

    @Test("validation rejects more than the maximum archive entry count")
    func rejectsTooManyFiles() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let meetingData = try makeTransferMeeting().encodedData()
        let notesData = Data("n".utf8)
        let transcriptData = try makeTransferTranscript().encodedData()
        var payload: [(String, Data, String)] = [
            ("meeting.json", meetingData, "application/json"),
            ("notes.md", notesData, "text/markdown"),
            ("transcript.json", transcriptData, "application/json"),
        ]
        for track in 1...14 {
            payload.append(("audio/track-\(track).caf", Data([UInt8(track)]), "audio/x-caf"))
            payload.append(("audio/track-\(track).json", Data([UInt8(track)]), "application/json"))
        }
        let manifestEntries = payload.map {
            MeetingTransferManifest.Entry(
                path: $0.0,
                byteCount: Int64($0.1.count),
                mediaType: $0.2,
                sha256: transferTestSHA256($0.1)
            )
        }
        let manifest = try MeetingTransferManifest(
            sourceMeetingID: transferTestMeetingID,
            sourceRevisionID: nil,
            exportedAt: .distantPast,
            sourceAppVersion: nil,
            capabilities: [.notes, .transcript, .audio],
            localeIdentifier: "de-DE",
            localeOrigin: .explicit,
            entries: manifestEntries,
            contentDigest: try MeetingTransferDigest.contentDigest(for: manifestEntries)
        )
        let archiveURL = base.appendingPathComponent("too-many.stenomeeting")
        let entries = [TransferTestArchiveEntry.regular(
            path: "manifest.json",
            data: try manifest.encodedData()
        )] + payload.map {
            TransferTestArchiveEntry.regular(path: $0.0, data: $0.1)
        } + [.regular(path: "audio/track-15.caf", data: Data([15]))]
        #expect(entries.count == MeetingTransferLimits.maximumFileCount + 1)
        try writeTransferRawArchive(entries, to: archiveURL)

        await expectValidationError(
            .fileCountExceedsLimit,
            at: archiveURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
    }

    @Test("validation rejects an outer file larger than the transport ceiling")
    func rejectsOversizedOuterFile() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let archiveURL = base.appendingPathComponent("oversized.stenomeeting")
        let descriptor = open(
            archiveURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, MeetingTransferLimits.maximumTransportFileBytes + 1) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        await expectValidationError(
            .transportFileExceedsLimit,
            at: archiveURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
    }

    @Test("hash mismatch never yields a validated payload")
    func rejectsHashMismatch() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        var entries = fixture.archiveEntries
        let index = entries.firstIndex { entry in
            entry.fields.contains {
                if case .string("PAT", "notes.md") = $0 { return true }
                return false
            }
        }!
        let original = fixture.payloadEntries.first { $0.path == "notes.md" }!.data
        var changed = original
        changed[changed.startIndex] ^= 0xff
        entries[index] = .regular(path: "notes.md", data: changed)
        let archiveURL = base.appendingPathComponent("hash.stenomeeting")
        try writeTransferRawArchive(entries, to: archiveURL)

        await expectValidationError(
            .hashMismatch("notes.md"),
            at: archiveURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
    }

    @Test("validation rejects an incorrect canonical content digest")
    func rejectsContentDigestMismatch() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let manifestData = try transferTestJSON(from: fixture.manifestData) {
            $0["contentDigest"] = String(repeating: "0", count: 64)
        }
        let archiveURL = base.appendingPathComponent("digest.stenomeeting")
        try writeTransferRawArchive(
            fixture.archiveEntries(manifestData: manifestData),
            to: archiveURL
        )

        await expectValidationError(
            .contentDigestMismatch,
            at: archiveURL,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
    }

    @Test("validation rejects corrupt audio and audio with zero samples")
    func rejectsInvalidAudioContent() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let corruptURL = base.appendingPathComponent("corrupt.caf")
        try Data("not audio".utf8).write(to: corruptURL)
        let corruptDocument = try await makeTransferAudioDocument(
            logicalTrackID: "corrupt",
            kind: .micTrack,
            sourceURL: corruptURL,
            duration: 1
        )
        let corruptContent = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [corruptDocument]
        )
        let corruptFixture = try await makeTransferPackageFixture(
            content: corruptContent,
            audioSources: ["corrupt": corruptURL]
        )
        let corruptArchive = base.appendingPathComponent("corrupt.stenomeeting")
        try writeTransferRawArchive(corruptFixture.archiveEntries, to: corruptArchive)
        await expectValidationError(
            .unsupportedAudio("corrupt"),
            at: corruptArchive,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-corrupt")
        )

        let emptyURL = base.appendingPathComponent("empty.caf")
        try makeTransferCAF(at: emptyURL, frameCount: 0)
        let emptyDocument = try await makeTransferAudioDocument(
            logicalTrackID: "empty",
            kind: .micTrack,
            sourceURL: emptyURL,
            duration: 1
        )
        let emptyContent = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [emptyDocument]
        )
        let emptyFixture = try await makeTransferPackageFixture(
            content: emptyContent,
            audioSources: ["empty": emptyURL]
        )
        let emptyArchive = base.appendingPathComponent("empty.stenomeeting")
        try writeTransferRawArchive(emptyFixture.archiveEntries, to: emptyArchive)
        await expectValidationError(
            .emptyAudio("empty"),
            at: emptyArchive,
            validationRoot: makeTransferTestRoot(under: base, name: "validation-empty")
        )
    }

    @Test("validation rejects readable non-CAF bytes under a CAF path")
    func rejectsReadableNonCAFContainer() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.wav")
        try makeTransferCAF(at: source)
        #expect(try Data(contentsOf: source).prefix(4) == Data("RIFF".utf8))
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "not-caf",
            kind: .micTrack,
            sourceURL: source
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )
        let fixture = try await makeTransferPackageFixture(
            content: content,
            audioSources: ["not-caf": source]
        )
        let archive = base.appendingPathComponent("not-caf.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)

        await expectValidationError(
            .unsupportedAudio("not-caf"),
            at: archive,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
    }

    @Test("snapshot hashing and parsing stay on the originally opened descriptor")
    func sourceReplacementCannotChangeSnapshot() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let originalFixture = try await makeTransferPackageFixture(
            content: makeTransferTextContent(notes: "original", transcript: nil)
        )
        let replacementFixture = try await makeTransferPackageFixture(
            content: makeTransferTextContent(notes: "replaced", transcript: nil)
        )
        let source = base.appendingPathComponent("source.stenomeeting")
        let replacement = base.appendingPathComponent("replacement.stenomeeting")
        try writeTransferRawArchive(originalFixture.archiveEntries, to: source)
        try writeTransferRawArchive(replacementFixture.archiveEntries, to: replacement)
        let expectedDigest = transferTestSHA256(try Data(contentsOf: source))
        let didReplace = Mutex(false)
        let reader = MeetingTransferArchiveReader(snapshotDidCopy: { _ in
            try didReplace.withLock { replaced in
                guard !replaced else { return }
                replaced = true
                try FileManager.default.removeItem(at: source)
                try FileManager.default.moveItem(at: replacement, to: source)
            }
        })

        let validated = try await reader.validate(
            at: source,
            validationRoot: makeTransferTestRoot(under: base, name: "validation")
        )
        defer { try? validated.close() }
        #expect(validated.notes == "original")
        #expect(validated.transportDigest == expectedDigest)
        let externalBytes = try Data(contentsOf: source)
        let snapshotBytes = try Data(contentsOf: validated.snapshotURL)
        #expect(externalBytes != snapshotBytes)
    }

    @Test("snapshot append race never writes beyond the initially checked size")
    func sourceAppendCannotExceedSnapshotReservation() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let source = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: source)
        let initialByteCount = Int64(try Data(contentsOf: source).count)
        let didAppend = Mutex(false)
        let writtenSnapshotBytes = Mutex<Int64>(0)
        let reader = MeetingTransferArchiveReader(
            snapshotDidCopy: { _ in
                try didAppend.withLock { appended in
                    guard !appended else { return }
                    appended = true
                    let handle = try FileHandle(forWritingTo: source)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data(repeating: 0xa5, count: 128))
                    try handle.synchronize()
                }
            },
            beforeWrite: { stage, count in
                if stage == .snapshot {
                    writtenSnapshotBytes.withLock { $0 += Int64(count) }
                }
            }
        )
        let validationRoot = makeTransferTestRoot(under: base, name: "validation")

        await expectValidationError(
            .sourceChangedDuringSnapshot,
            at: source,
            validationRoot: validationRoot,
            reader: reader
        )

        #expect(didAppend.withLock { $0 })
        #expect(writtenSnapshotBytes.withLock { $0 } == initialByteCount)
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("capacity and disk-full failures remove every owned session artifact")
    func storageFailuresCleanOwnedSession() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)

        for stage in [MeetingTransferStorageStage.snapshot, .entries] {
            let root = makeTransferTestRoot(under: base, name: "capacity-\(stage)")
            let reader = MeetingTransferArchiveReader(capacityCheck: { checkedStage, _ in
                if checkedStage == stage {
                    throw MeetingTransferValidationError.insufficientCapacity(stage)
                }
            })
            await expectValidationError(
                .insufficientCapacity(stage),
                at: archive,
                validationRoot: root,
                reader: reader
            )
            #expect(try transferDirectoryContents(root).isEmpty)
        }

        let diskFullRoot = makeTransferTestRoot(under: base, name: "disk-full")
        let diskFullReader = MeetingTransferArchiveReader(beforeWrite: { stage, _ in
            if stage == .snapshot {
                throw MeetingTransferValidationError.storageWriteFailed
            }
        })
        await expectValidationError(
            .storageWriteFailed,
            at: archive,
            validationRoot: diskFullRoot,
            reader: diskFullReader
        )
        #expect(try transferDirectoryContents(diskFullRoot).isEmpty)
    }

    @Test("every late cancellation checkpoint removes the owned session")
    func lateCancellationCleansSession() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "room",
            kind: .micTrack,
            sourceURL: audioURL
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: "notes",
            transcript: nil,
            audio: [document]
        )
        let fixture = try await makeTransferPackageFixture(
            content: content,
            audioSources: ["room": audioURL]
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let cancellationPoints: [MeetingTransferValidationCheckpoint] = [
            .beforePayloadDecode,
            .beforeAudio(0),
            .beforeReturn,
        ]

        for (offset, cancellationPoint) in cancellationPoints.enumerated() {
            let validationRoot = makeTransferTestRoot(
                under: base,
                name: "validation-cancel-\(offset)"
            )
            let checkpoints = Mutex<[MeetingTransferValidationCheckpoint]>([])
            let reader = MeetingTransferArchiveReader(validationCheckpoint: { checkpoint in
                checkpoints.withLock { $0.append(checkpoint) }
                if checkpoint == cancellationPoint {
                    throw CancellationError()
                }
            })

            do {
                let value = try await reader.validate(at: archive, validationRoot: validationRoot)
                try? value.close()
                Issue.record("Validation returned a value after injected cancellation")
            } catch is CancellationError {
                // Expected.
            } catch {
                Issue.record("Unexpected cancellation error: \(error)")
            }

            #expect(checkpoints.withLock { $0 }.contains(cancellationPoint))
            #expect(try transferDirectoryContents(validationRoot).isEmpty)
        }
    }

    @Test("small payload decoding stays bound to the bytes that were hashed")
    func stagedPayloadReplacementCannotChangeDecodedNotes() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(
            content: makeTransferTextContent(notes: "original", transcript: nil)
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-binding")
        let replacedFiles = Mutex<(original: URL, saved: URL)?>(nil)
        let reader = MeetingTransferArchiveReader(validationCheckpoint: { checkpoint in
            guard checkpoint == .beforePayloadDecode else { return }
            let sessionName = try transferDirectoryContents(validationRoot).first!
            let sessionURL = validationRoot.appendingPathComponent(sessionName)
            let original = sessionURL.appendingPathComponent("entry-0003")
            let saved = sessionURL.appendingPathComponent("saved-notes")
            try FileManager.default.moveItem(at: original, to: saved)
            try Data("replacement".utf8).write(to: original)
            #expect(chmod(original.path, S_IRUSR | S_IWUSR) == 0)
            replacedFiles.withLock { $0 = (original, saved) }
        })

        let validated = try await reader.validate(at: archive, validationRoot: validationRoot)
        #expect(validated.notes == "original")

        let replacement = replacedFiles.withLock { $0 }
        #expect(replacement != nil)
        if let replacement {
            try FileManager.default.removeItem(at: replacement.original)
            try FileManager.default.moveItem(at: replacement.saved, to: replacement.original)
        }
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("validated audio lease stays on the hashed inode and blocks concurrent close")
    func stagedAudioReplacementCannotChangeLeasedSource() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL, frameCount: 160)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "room",
            kind: .micTrack,
            sourceURL: audioURL,
            duration: 0.02
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )
        let fixture = try await makeTransferPackageFixture(
            content: content,
            audioSources: ["room": audioURL]
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        var changedAudioBytes = try Data(contentsOf: audioURL)
        changedAudioBytes[changedAudioBytes.index(before: changedAudioBytes.endIndex)] ^= 0x01
        let replacementBytes = changedAudioBytes
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-audio-binding")
        let replacementURL = Mutex<URL?>(nil)
        let reader = MeetingTransferArchiveReader(validationCheckpoint: { checkpoint in
            guard checkpoint == .beforeAudio(0) else { return }
            let sessionName = try transferDirectoryContents(validationRoot).first!
            let sessionURL = validationRoot.appendingPathComponent(sessionName)
            let original = sessionURL.appendingPathComponent("entry-0003")
            #expect(!FileManager.default.fileExists(atPath: original.path))
            try replacementBytes.write(to: original)
            #expect(chmod(original.path, S_IRUSR | S_IWUSR) == 0)
            replacementURL.withLock { $0 = original }
        })

        let validated = try await reader.validate(at: archive, validationRoot: validationRoot)
        let sourceLease = try validated.audio[0].leaseSource()
        let leasedDigest = try await MeetingTransferDigest.sha256(of: sourceLease.sourceURL)
        #expect(leasedDigest == document.sha256)
        let concurrentCloseError = await Task.detached {
            do {
                try validated.close()
                return nil as MeetingTransferValidationError?
            } catch let error as MeetingTransferValidationError {
                return error
            } catch {
                return .cleanupFailed("unexpected")
            }
        }.value
        #expect(concurrentCloseError == .sessionInUse)
        #expect(FileManager.default.fileExists(atPath: validated.sessionDirectoryURL.path))
        sourceLease.close()

        let replacement = replacementURL.withLock { $0 }
        #expect(replacement != nil)
        if let replacement {
            #expect(try Data(contentsOf: replacement) == replacementBytes)
            try FileManager.default.removeItem(at: replacement)
        }
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("an audio staging-name replacement before return cannot change validated bytes")
    func audioReplacementBeforeReturnCannotChangeValidatedBytes() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "room",
            kind: .micTrack,
            sourceURL: audioURL
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )
        let fixture = try await makeTransferPackageFixture(
            content: content,
            audioSources: ["room": audioURL]
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-audio-mutate")
        var changedAudioBytes = try Data(contentsOf: audioURL)
        changedAudioBytes[changedAudioBytes.index(before: changedAudioBytes.endIndex)] ^= 0x01
        let replacementBytes = changedAudioBytes
        let replacementURL = Mutex<URL?>(nil)
        let reader = MeetingTransferArchiveReader(validationCheckpoint: { checkpoint in
            guard checkpoint == .beforeReturn else { return }
            let sessionName = try transferDirectoryContents(validationRoot).first!
            let stagedAudio = validationRoot
                .appendingPathComponent(sessionName)
                .appendingPathComponent("entry-0003")
            #expect(!FileManager.default.fileExists(atPath: stagedAudio.path))
            try replacementBytes.write(to: stagedAudio)
            #expect(chmod(stagedAudio.path, S_IRUSR | S_IWUSR) == 0)
            replacementURL.withLock { $0 = stagedAudio }
        })

        let validated = try await reader.validate(at: archive, validationRoot: validationRoot)
        let lease = try validated.audio[0].leaseSource()
        let bytes = try Data(contentsOf: lease.sourceURL)
        #expect(transferTestSHA256(bytes) == document.sha256)
        lease.close()
        if let replacement = replacementURL.withLock({ $0 }) {
            #expect(try Data(contentsOf: replacement) == replacementBytes)
            try FileManager.default.removeItem(at: replacement)
        }
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("a successful audio lease remains immutable through every former staging name")
    func audioLeaseIsDetachedFromWritableStagingNames() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "room",
            kind: .micTrack,
            sourceURL: audioURL
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: nil,
            transcript: nil,
            audio: [document]
        )
        let fixture = try await makeTransferPackageFixture(
            content: content,
            audioSources: ["room": audioURL]
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-audio-recheck")
        let validated = try await MeetingTransferArchiveReader().validate(
            at: archive,
            validationRoot: validationRoot
        )
        let stagedAudio = validated.sessionDirectoryURL.appendingPathComponent("entry-0003")
        let originalBytes = try Data(contentsOf: audioURL)
        var replacementBytes = originalBytes
        replacementBytes[replacementBytes.index(before: replacementBytes.endIndex)] ^= 0x01
        let lease = try validated.audio[0].leaseSource()

        let stagingWriteDescriptor = open(
            stagedAudio.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        if stagingWriteDescriptor >= 0 {
            try writeTransferBytes(replacementBytes, to: stagingWriteDescriptor)
            _ = Darwin.close(stagingWriteDescriptor)
        }
        #expect(stagingWriteDescriptor == -1)

        try replacementBytes.write(to: stagedAudio)
        #expect(chmod(stagedAudio.path, S_IRUSR | S_IWUSR) == 0)

        let leaseWriteDescriptor = open(lease.sourceURL.path, O_WRONLY | O_CLOEXEC)
        if leaseWriteDescriptor >= 0 {
            var byte: UInt8 = 0xff
            #expect(pwrite(leaseWriteDescriptor, &byte, 1, 0) == -1)
            _ = Darwin.close(leaseWriteDescriptor)
        }

        var leaseStatus = stat()
        #expect(stat(lease.sourceURL.path, &leaseStatus) == 0)
        #expect(leaseStatus.st_nlink == 0)
        let leasedBytes = try Data(contentsOf: lease.sourceURL)
        #expect(leasedBytes == originalBytes)
        #expect(transferTestSHA256(leasedBytes) == document.sha256)
        #expect(try Data(contentsOf: stagedAudio) == replacementBytes)

        lease.close()
        try FileManager.default.removeItem(at: stagedAudio)
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("cleanup failure is visible and a later close retries it")
    func cleanupFailureCanBeRetried() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-cleanup-retry")
        let failCleanup = Mutex(true)
        let reader = MeetingTransferArchiveReader(cleanupAction: { target in
            if target == .file("entry-0003"), failCleanup.withLock({ $0 }) {
                throw POSIXError(.EIO)
            }
        })
        let validated = try await reader.validate(at: archive, validationRoot: validationRoot)

        #expect(throws: MeetingTransferValidationError.cleanupFailed("entry-0003")) {
            try validated.close()
        }
        #expect(try !transferDirectoryContents(validationRoot).isEmpty)

        failCleanup.withLock { $0 = false }
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("failed validation returns an explicit retryable cleanup handle")
    func failedValidationCleanupCanBeRetriedWithoutRestart() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = base.appendingPathComponent("invalid.stenomeeting")
        try writeTransferRawArchiveBytes(Data("not-an-archive".utf8), to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-failed-cleanup")
        let failCleanup = Mutex(true)
        let reader = MeetingTransferArchiveReader(cleanupAction: { _ in
            if failCleanup.withLock({ $0 }) {
                throw POSIXError(.EIO)
            }
        })

        do {
            _ = try await reader.validate(at: archive, validationRoot: validationRoot)
            Issue.record("expected validation failure with retained cleanup handle")
        } catch let error as MeetingTransferCleanupRequired {
            #expect(error.originalError as? MeetingTransferValidationError == .notRawAppleArchive)
            #expect(!error.cleanupHandle.sessionIdentity.isEmpty)
            #expect(try transferDirectoryContents(validationRoot).count == 1)
            failCleanup.withLock { $0 = false }
            try error.cleanupHandle.close()
        }

        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("failed revalidation returns an explicit retryable cleanup handle")
    func failedRevalidationCleanupCanBeRetriedWithoutRestart() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(
            content: makeTransferTextContent(notes: "original", transcript: nil)
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(
            under: base,
            name: "validation-revalidation-cleanup"
        )
        let validated = try await MeetingTransferArchiveReader().validate(
            at: archive,
            validationRoot: validationRoot
        )
        let originalSize = try Data(contentsOf: validated.snapshotURL).count
        try Data(repeating: 0, count: originalSize).write(to: validated.snapshotURL)
        let failCleanup = Mutex(true)
        let revalidatingReader = MeetingTransferArchiveReader(cleanupAction: { _ in
            if failCleanup.withLock({ $0 }) {
                throw POSIXError(.EIO)
            }
        })

        do {
            _ = try await revalidatingReader.revalidate(validated)
            Issue.record("expected revalidation failure with retained cleanup handle")
        } catch let error as MeetingTransferCleanupRequired {
            #expect(error.originalError as? MeetingTransferValidationError == .notRawAppleArchive)
            #expect(try transferDirectoryContents(validationRoot).count == 2)
            failCleanup.withLock { $0 = false }
            try error.cleanupHandle.close()
        }

        #expect(try transferDirectoryContents(validationRoot).count == 1)
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("owned snapshot cleanup retains the original validation error")
    func failedOwnedSnapshotCleanupRetainsValidationError() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let exportRoot = makeTransferTestRoot(under: base, name: "owned-snapshot")
        let failCleanup = Mutex(true)
        let root = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: exportRoot,
            cleanupAction: { _ in
                if failCleanup.withLock({ $0 }) {
                    throw POSIXError(.EIO)
                }
            }
        )
        let archiveName = ".stenomeeting-staging-\(UUID().uuidString)"
        let archive = exportRoot.appendingPathComponent(archiveName)
        try writeTransferRawArchiveBytes(Data("not-an-archive".utf8), to: archive)
        let descriptor = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { _ = Darwin.close(descriptor) }

        do {
            _ = try await MeetingTransferArchiveReader().validateOwnedSnapshot(
                fileDescriptor: descriptor,
                archiveURL: archive,
                within: root
            )
            Issue.record("expected owned snapshot validation failure")
        } catch let error as MeetingTransferCleanupRequired {
            #expect(error.originalError as? MeetingTransferValidationError == .notRawAppleArchive)
            #expect(!error.cleanupHandle.sessionIdentity.isEmpty)
            failCleanup.withLock { $0 = false }
            try error.cleanupHandle.close()
        }

        #expect(try transferDirectoryContents(exportRoot) == [archiveName])
    }

    @Test("cleanup handles retain initial and revalidation hash and audio failures")
    func cleanupHandlesCoverHashAndAudioFailures() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let audioURL = base.appendingPathComponent("audio.caf")
        try makeTransferCAF(at: audioURL)
        let document = try await makeTransferAudioDocument(
            logicalTrackID: "room",
            kind: .micTrack,
            sourceURL: audioURL
        )
        let content = try MeetingTransferPackageContent(
            meeting: makeTransferMeeting(),
            notes: "notes",
            transcript: nil,
            audio: [document]
        )
        let fixture = try await makeTransferPackageFixture(
            content: content,
            audioSources: ["room": audioURL]
        )
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)

        let initialCases: [(String, Bool, MeetingTransferValidationError)] = [
            ("initial-hash", false, .sourceChangedDuringSnapshot),
            ("initial-audio", true, .unsupportedAudio("injected")),
        ]
        for (name, isAudioFailure, expected) in initialCases {
            let validationRoot = makeTransferTestRoot(under: base, name: name)
            let failCleanup = Mutex(true)
            let cleanup: MeetingTransferCleanupAction = { _ in
                if failCleanup.withLock({ $0 }) { throw POSIXError(.EIO) }
            }
            let reader: MeetingTransferArchiveReader
            if isAudioFailure {
                reader = MeetingTransferArchiveReader(
                    validationCheckpoint: { checkpoint in
                        guard checkpoint == .beforeAudio(0) else { return }
                        throw MeetingTransferValidationError.unsupportedAudio("injected")
                    },
                    cleanupAction: cleanup
                )
            } else {
                reader = MeetingTransferArchiveReader(
                    snapshotDidCopy: { _ in
                        throw MeetingTransferValidationError.sourceChangedDuringSnapshot
                    },
                    cleanupAction: cleanup
                )
            }
            do {
                _ = try await reader.validate(at: archive, validationRoot: validationRoot)
                Issue.record("expected \(name) cleanup handle")
            } catch let error as MeetingTransferCleanupRequired {
                #expect(error.originalError as? MeetingTransferValidationError == expected)
                #expect(!error.cleanupHandle.sessionIdentity.isEmpty)
                #expect(try transferDirectoryContents(validationRoot).count == 1)
                failCleanup.withLock { $0 = false }
                try error.cleanupHandle.close()
            }
            #expect(try transferDirectoryContents(validationRoot).isEmpty)
        }

        let revalidationCases: [(String, Bool, MeetingTransferValidationError)] = [
            ("revalidate-hash", true, .hashMismatch("notes.md")),
            ("revalidate-audio", false, .unsupportedAudio("injected")),
        ]
        for (name, mutate, expected) in revalidationCases {
            let validationRoot = makeTransferTestRoot(under: base, name: name)
            let validated = try await MeetingTransferArchiveReader().validate(
                at: archive,
                validationRoot: validationRoot
            )
            if mutate {
                var bytes = try Data(contentsOf: validated.snapshotURL)
                let marker = Data("notes".utf8)
                let range = try #require(bytes.range(of: marker, options: .backwards))
                bytes[range.lowerBound] ^= 0x01
                try bytes.write(to: validated.snapshotURL)
            }
            let failCleanup = Mutex(true)
            let cleanup: MeetingTransferCleanupAction = { _ in
                if failCleanup.withLock({ $0 }) { throw POSIXError(.EIO) }
            }
            let reader = mutate
                ? MeetingTransferArchiveReader(cleanupAction: cleanup)
                : MeetingTransferArchiveReader(
                    validationCheckpoint: { checkpoint in
                        guard checkpoint == .beforeAudio(0) else { return }
                        throw MeetingTransferValidationError.unsupportedAudio("injected")
                    },
                    cleanupAction: cleanup
                )
            do {
                _ = try await reader.revalidate(validated)
                Issue.record("expected \(name) cleanup handle")
            } catch let error as MeetingTransferCleanupRequired {
                #expect(error.originalError as? MeetingTransferValidationError == expected)
                #expect(!error.cleanupHandle.sessionIdentity.isEmpty)
                #expect(try transferDirectoryContents(validationRoot).count == 2)
                failCleanup.withLock { $0 = false }
                try error.cleanupHandle.close()
            }
            try validated.close()
            #expect(try transferDirectoryContents(validationRoot).isEmpty)
        }
    }

    @Test("cleanup never unlinks a name-swapped staged-file replacement")
    func cleanupRejectsStagedFileNameSwap() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-file-swap")
        let validated = try await MeetingTransferArchiveReader().validate(
            at: archive,
            validationRoot: validationRoot
        )
        let original = validated.sessionDirectoryURL.appendingPathComponent("entry-0002")
        let saved = validated.sessionDirectoryURL.appendingPathComponent("saved-entry")
        try FileManager.default.moveItem(at: original, to: saved)
        let replacementBytes = Data("must-survive".utf8)
        try replacementBytes.write(to: original)
        #expect(chmod(original.path, S_IRUSR | S_IWUSR) == 0)

        #expect(throws: MeetingTransferValidationError.cleanupIdentityMismatch("entry-0002")) {
            try validated.close()
        }
        #expect(try Data(contentsOf: original) == replacementBytes)

        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: saved, to: original)
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("cleanup quarantines a file swapped after identity verification")
    func cleanupRejectsFileSwapBetweenCheckAndRemoval() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-file-gap")
        let sessionName = Mutex<String?>(nil)
        let didSwap = Mutex(false)
        let swappedName = Mutex<String?>(nil)
        let savedOwned = validationRoot.appendingPathComponent("saved-owned-file")
        let replacementBytes = Data("replacement-must-survive".utf8)
        let root = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: validationRoot,
            cleanupAction: { _ in },
            namespaceCheckpoint: { checkpoint in
                guard case let .beforeFileRemoval(currentName) = checkpoint else { return }
                try didSwap.withLock { swapped in
                    guard !swapped else { return }
                    guard let name = sessionName.withLock({ $0 }) else {
                        throw POSIXError(.EIO)
                    }
                    let sessionURL = validationRoot.appendingPathComponent(name)
                    let current = sessionURL.appendingPathComponent(currentName)
                    try FileManager.default.moveItem(at: current, to: savedOwned)
                    try replacementBytes.write(to: current)
                    guard chmod(current.path, S_IRUSR | S_IWUSR) == 0 else {
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                    swappedName.withLock { $0 = currentName }
                    swapped = true
                }
            }
        )
        let session = try root.createSession()
        sessionName.withLock { $0 = session.name }
        let descriptor = try session.createFile(named: "owned.bin")
        try writeTransferBytes(Data("owned".utf8), to: descriptor.rawValue)
        descriptor.close()

        #expect(throws: MeetingTransferValidationError.cleanupIdentityMismatch("owned.bin")) {
            try session.cleanup()
        }
        let currentName = try #require(swappedName.withLock { $0 })
        let replacement = session.url.appendingPathComponent(currentName)
        #expect(try Data(contentsOf: replacement) == replacementBytes)
        #expect(FileManager.default.fileExists(atPath: savedOwned.path))

        try FileManager.default.removeItem(at: replacement)
        try FileManager.default.moveItem(
            at: savedOwned,
            to: session.url.appendingPathComponent("owned.bin")
        )
        try session.cleanup()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("cleanup never removes a name-swapped replacement session")
    func cleanupRejectsSessionNameSwap() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-session-swap")
        let validated = try await MeetingTransferArchiveReader().validate(
            at: archive,
            validationRoot: validationRoot
        )
        let originalSession = validated.sessionDirectoryURL
        let savedSession = validationRoot.appendingPathComponent("saved-session")
        try FileManager.default.moveItem(at: originalSession, to: savedSession)
        try FileManager.default.createDirectory(at: originalSession, withIntermediateDirectories: false)
        #expect(chmod(originalSession.path, S_IRWXU) == 0)
        let replacement = originalSession.appendingPathComponent("must-survive")
        let replacementBytes = Data("replacement-session".utf8)
        try replacementBytes.write(to: replacement)

        #expect(throws: MeetingTransferValidationError.cleanupIdentityMismatch(
            originalSession.lastPathComponent
        )) {
            try validated.close()
        }
        #expect(try Data(contentsOf: replacement) == replacementBytes)

        try FileManager.default.removeItem(at: originalSession)
        try FileManager.default.moveItem(at: savedSession, to: originalSession)
        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("cleanup quarantines a session swapped after identity verification")
    func cleanupRejectsSessionSwapBetweenCheckAndRemoval() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let validationRoot = makeTransferTestRoot(under: base, name: "validation-session-gap")
        let didSwap = Mutex(false)
        let swappedName = Mutex<String?>(nil)
        let replacementIdentity = Mutex<MeetingTransferFileIdentity?>(nil)
        let savedOwned = validationRoot.appendingPathComponent("saved-owned-session")
        let root = try MeetingTransferPrivateRoot.prepareAndVerify(
            at: validationRoot,
            cleanupAction: { _ in },
            namespaceCheckpoint: { checkpoint in
                guard case let .beforeSessionDirectoryRemoval(currentName) = checkpoint else {
                    return
                }
                try didSwap.withLock { swapped in
                    guard !swapped else { return }
                    let current = validationRoot.appendingPathComponent(currentName)
                    try FileManager.default.moveItem(at: current, to: savedOwned)
                    try FileManager.default.createDirectory(
                        at: current,
                        withIntermediateDirectories: false
                    )
                    guard chmod(current.path, S_IRWXU) == 0 else {
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                    var status = stat()
                    guard lstat(current.path, &status) == 0 else {
                        throw POSIXError(.init(rawValue: errno) ?? .EIO)
                    }
                    replacementIdentity.withLock { $0 = MeetingTransferFileIdentity(status) }
                    swappedName.withLock { $0 = currentName }
                    swapped = true
                }
            }
        )
        let session = try root.createSession()

        #expect(throws: MeetingTransferValidationError.cleanupIdentityMismatch(session.name)) {
            try session.cleanup()
        }
        let currentName = try #require(swappedName.withLock { $0 })
        let replacement = validationRoot.appendingPathComponent(currentName)
        var currentStatus = stat()
        #expect(lstat(replacement.path, &currentStatus) == 0)
        #expect(MeetingTransferFileIdentity(currentStatus) == replacementIdentity.withLock { $0 })
        #expect(FileManager.default.fileExists(atPath: savedOwned.path))

        try FileManager.default.removeItem(at: replacement)
        try FileManager.default.moveItem(at: savedOwned, to: session.url)
        try session.cleanup()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("private validation sessions use 0700 directories and 0600 files then close cleanly")
    func privateSessionPermissionsAndCleanup() async throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await makeTransferPackageFixture(content: makeTransferTextContent())
        let archive = base.appendingPathComponent("source.stenomeeting")
        try writeTransferRawArchive(fixture.archiveEntries, to: archive)
        let validationRoot = makeTransferTestRoot(under: base, name: "validation")

        let validated = try await MeetingTransferArchiveReader().validate(
            at: archive,
            validationRoot: validationRoot
        )
        var rootStat = stat()
        var sessionStat = stat()
        #expect(lstat(validationRoot.path, &rootStat) == 0)
        #expect(lstat(validated.sessionDirectoryURL.path, &sessionStat) == 0)
        #expect(rootStat.st_mode & 0o777 == 0o700)
        #expect(sessionStat.st_mode & 0o777 == 0o700)
        for name in try transferDirectoryContents(validated.sessionDirectoryURL) {
            var fileStat = stat()
            let url = validated.sessionDirectoryURL.appendingPathComponent(name)
            #expect(lstat(url.path, &fileStat) == 0)
            #expect(fileStat.st_mode & 0o777 == 0o600)
        }

        try validated.close()
        #expect(try transferDirectoryContents(validationRoot).isEmpty)
    }

    @Test("private root verification rejects files symlinks and broad permissions")
    func privateRootFailsClosed() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("file-root")
        try Data().write(to: file)
        #expect(throws: MeetingTransferValidationError.privateRootIsNotDirectory) {
            try MeetingTransferPrivateRoot.prepareAndVerify(at: file)
        }

        let broad = base.appendingPathComponent("broad-root", isDirectory: true)
        try FileManager.default.createDirectory(at: broad, withIntermediateDirectories: false)
        #expect(chmod(broad.path, 0o755) == 0)
        #expect(throws: MeetingTransferValidationError.insecurePrivateRootPermissions) {
            try MeetingTransferPrivateRoot.prepareAndVerify(at: broad)
        }

        let specialBits = base.appendingPathComponent("special-bits-root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: specialBits,
            withIntermediateDirectories: false
        )
        #expect(chmod(specialBits.path, 0o1700) == 0)
        var specialBitsStatus = stat()
        #expect(lstat(specialBits.path, &specialBitsStatus) == 0)
        #expect(specialBitsStatus.st_mode & 0o7777 == 0o1700)
        #expect(throws: MeetingTransferValidationError.insecurePrivateRootPermissions) {
            try MeetingTransferPrivateRoot.prepareAndVerify(at: specialBits)
        }

        let link = base.appendingPathComponent("link-root")
        #expect(symlink(broad.path, link.path) == 0)
        #expect(throws: MeetingTransferValidationError.privateRootIsSymbolicLink) {
            try MeetingTransferPrivateRoot.prepareAndVerify(at: link)
        }
    }

    private func expectValidationError(
        _ expected: MeetingTransferValidationError,
        at archive: URL,
        validationRoot: URL,
        reader: MeetingTransferArchiveReader = MeetingTransferArchiveReader()
    ) async {
        do {
            let value = try await reader.validate(at: archive, validationRoot: validationRoot)
            try? value.close()
            Issue.record("Validation unexpectedly accepted \(archive.lastPathComponent)")
        } catch let error as MeetingTransferValidationError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error for \(archive.lastPathComponent): \(error)")
        }
    }
}
