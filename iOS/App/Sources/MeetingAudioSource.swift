import Foundation
import StenoDomain
import StenoLibrary

/// A registered original recording. Paths are checked again immediately before playback.
struct MeetingAudioSource: Identifiable, Sendable {
    let asset: MediaAsset
    var id: MediaAssetID { asset.id }

    private let layout: LibraryLayout
    private let meetingID: MeetingID
    private let canonicalRoot: URL

    static func load(in library: Library, meetingID: MeetingID) async throws -> [Self] {
        let layout = library.layout
        let root = layout.root.resolvingSymlinksInPath().standardizedFileURL
        try validateDirectories(layout: layout, meetingID: meetingID, canonicalRoot: root)
        let assets = try await library.listMediaAssets(meetingID: meetingID)
        guard Set(assets.map(\.id)).count == assets.count else {
            throw MeetingAudioSourceError.duplicateAsset
        }
        return try assets.sorted {
            if $0.kind == $1.kind { return $0.id < $1.id }
            return $0.kind.rawValue < $1.kind.rawValue
        }.map { asset in
            let source = Self(asset: asset, layout: layout, meetingID: meetingID, canonicalRoot: root)
            _ = try source.validatedURL()
            return source
        }
    }

    func validatedURL() throws -> URL {
        guard asset.meetingID == meetingID else { throw MeetingAudioSourceError.wrongMeeting }
        let name = asset.fileName
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw MeetingAudioSourceError.invalidFileName
        }
        try Self.validateDirectories(layout: layout, meetingID: meetingID, canonicalRoot: canonicalRoot)
        let url = layout.mediaFile(meetingID, fileName: name)
        try Self.requireType(.typeRegular, at: url)
        return url
    }

    private static func validateDirectories(
        layout: LibraryLayout, meetingID: MeetingID, canonicalRoot: URL
    ) throws {
        guard layout.root.resolvingSymlinksInPath().standardizedFileURL == canonicalRoot else {
            throw MeetingAudioSourceError.unsafePath
        }
        // Inspect each component below the library boundary without following links.
        // System aliases in ancestors (such as /tmp) are deliberately outside this boundary.
        for directory in [layout.root, layout.meetingsDirectory,
                          layout.meetingDirectory(meetingID), layout.mediaDirectory(meetingID)] {
            try requireType(.typeDirectory, at: directory)
        }
    }

    private static func requireType(_ expected: FileAttributeType, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == expected else {
            throw MeetingAudioSourceError.unsafePath
        }
    }
}

enum MeetingAudioSourceError: Error, LocalizedError, Equatable {
    case duplicateAsset
    case wrongMeeting
    case invalidFileName
    case unsafePath

    var errorDescription: String? {
        switch self {
        case .duplicateAsset: "The recording metadata contains duplicate audio identifiers."
        case .wrongMeeting: "The recording does not belong to this meeting."
        case .invalidFileName: "The recording has an invalid file name."
        case .unsafePath: "The recording path is not a regular local file in this meeting's media folder."
        }
    }
}
