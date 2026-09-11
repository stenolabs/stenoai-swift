import Foundation

public struct DemoProvenance: Codable, Equatable, Hashable, Sendable {
    public let datasetID: String
    public let datasetVersion: String
    public let itemID: String
    /// Lokale Identität genau einer sichtbaren Demo-Installation. Optional,
    /// damit ältere Meeting-Dokumente und gebündelte Transcript-Provenienz
    /// unverändert lesbar bleiben.
    public let installationGenerationID: MeetingTransferGenerationID?

    public init(
        datasetID: String,
        datasetVersion: String,
        itemID: String,
        installationGenerationID: MeetingTransferGenerationID? = nil
    ) {
        self.datasetID = datasetID
        self.datasetVersion = datasetVersion
        self.itemID = itemID
        self.installationGenerationID = installationGenerationID
    }
}

public struct MeetingMetadata: Codable, Equatable, Sendable {
    public let legacyProvenanceKey: String?
    public let legacyFolders: [String]
    public let transferReceipt: MeetingTransferReceipt?
    public let demoProvenance: DemoProvenance?
    /// Report template chosen for THIS meeting (recording-time pin).
    /// Optional so older documents decode unchanged; nil means the global
    /// default applies.
    public var pinnedTemplateID: String?

    public init(
        legacyProvenanceKey: String? = nil,
        legacyFolders: [String] = [],
        transferReceipt: MeetingTransferReceipt? = nil,
        demoProvenance: DemoProvenance? = nil,
        pinnedTemplateID: String? = nil
    ) {
        self.legacyProvenanceKey = legacyProvenanceKey
        self.legacyFolders = legacyFolders
        self.transferReceipt = transferReceipt
        self.demoProvenance = demoProvenance
        self.pinnedTemplateID = pinnedTemplateID
    }

    /// Returns a copy carrying the given pin (nil clears it). The other
    /// metadata fields stay immutable by design; only user-owned pins
    /// mutate after creation.
    public func withPinnedTemplateID(_ id: String?) -> MeetingMetadata {
        var copy = self
        copy.pinnedTemplateID = id
        return copy
    }
}

public struct Meeting: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: MeetingID
    public var title: String
    public let createdAt: Date
    public var status: Status
    /// Personen mit belegtem Redebeitrag in diesem Meeting: gepflegt von der
    /// Sprecherprüfung, an Sprachbeweise gebunden.
    public var participantIDs: [PersonID]
    /// Vom Benutzer ergänzte Anwesende ohne Sprachbeleg (stille Teilnehmer,
    /// oder Sprecher, die die Erkennung nicht getrennt hat). Bewusst getrennt
    /// gehalten: Die Sprecherprüfung räumt participantIDs ohne Beleg wieder
    /// ab, eine bewusste Nutzerangabe darf davon nie betroffen sein.
    public var additionalParticipantIDs: [PersonID]
    /// Der Ordner, in dem dieses Meeting liegt. Nil heisst nicht einsortiert;
    /// jede Aufnahme entsteht so und wandert erst durch eine bewusste
    /// Handlung in einen Ordner.
    ///
    /// Eine Kennung, zu der es keinen Ordner mehr gibt, gilt ueberall wie
    /// nil - ein geloeschter Ordner darf kein Meeting unerreichbar machen.
    public var folderID: FolderID?
    public let metadata: MeetingMetadata?
    /// Gesprochene Quellsprache dieses Meetings samt Herkunft der Angabe.
    ///
    /// Nil bedeutet, dass keine belastbare Quelle vorliegt. Insbesondere wird
    /// eine nur aus Geraeteeinstellungen abgeleitete Sprache nicht als
    /// ausdrueckliche Nutzerwahl gespeichert.
    public let sourceLocale: MeetingSourceLocale?
    /// Die ausdrücklich gewählten ASR-Provider für dieses Meeting.
    /// Nil bezeichnet ein ungepinntes (insbesondere ein altes) Meeting.
    public var transcriptionPlan: TranscriptionPlan?
    /// Tracks this recording should have had but never got, for example a
    /// microphone that Core Audio would not hand over while the recording ran.
    ///
    /// Stated explicitly rather than derived from the assets: a single track is
    /// normal on iOS and a defect on the Mac, so counting assets would be a
    /// guess. Anything that presents this meeting to a person - the library,
    /// and above all a generated report - has to be able to say that a side of
    /// the conversation is missing instead of silently leaving it out.
    public var unrecordedTracks: [MediaAsset.Kind]

    /// False when a track is known to be missing from this recording.
    public var isRecordingComplete: Bool { unrecordedTracks.isEmpty }

    public var isDemo: Bool {
        metadata?.demoProvenance != nil
    }

    /// Bindet jede produktive Verarbeitung an genau die sichtbare Meeting-
    /// Generation. Demo-Identität hat Vorrang, falls alte/ungewöhnliche
    /// Metadaten zusätzlich einen Transferbeleg enthalten.
    public var processingGenerationID: MeetingTransferGenerationID? {
        metadata?.demoProvenance?.installationGenerationID
            ?? metadata?.transferReceipt?.importGenerationID
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: MeetingID = MeetingID(),
        title: String,
        createdAt: Date = Date(),
        status: Status,
        participantIDs: [PersonID] = [],
        additionalParticipantIDs: [PersonID] = [],
        folderID: FolderID? = nil,
        metadata: MeetingMetadata? = nil,
        sourceLocale: MeetingSourceLocale? = nil,
        transcriptionPlan: TranscriptionPlan? = nil,
        unrecordedTracks: [MediaAsset.Kind] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.status = status
        self.participantIDs = participantIDs
        self.additionalParticipantIDs = additionalParticipantIDs
        self.folderID = folderID
        self.metadata = metadata
        self.sourceLocale = sourceLocale
        self.transcriptionPlan = transcriptionPlan
        self.unrecordedTracks = unrecordedTracks
    }

    public enum Status: String, Codable, Equatable, Sendable {
        /// Angelegt, aber nie aufgenommen: der Benutzer schreibt Notizen vor
        /// dem Termin. Ein Entwurf hat keine Originalspuren, ist deshalb nichts
        /// Gestrandetes und darf von keiner Wiederherstellung eingesammelt
        /// werden.
        case draft
        case recording
        case interrupted
        case ready
        case processing
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case title
        case createdAt
        case status
        case participantIDs
        case additionalParticipantIDs
        case folderID
        case metadata
        case sourceLocale
        case transcriptionPlan
        case unrecordedTracks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(MeetingID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(Status.self, forKey: .status)
        participantIDs = try container.decodeIfPresent(
            [PersonID].self,
            forKey: .participantIDs
        ) ?? []
        additionalParticipantIDs = try container.decodeIfPresent(
            [PersonID].self,
            forKey: .additionalParticipantIDs
        ) ?? []
        folderID = try container.decodeIfPresent(FolderID.self, forKey: .folderID)
        metadata = try container.decodeIfPresent(MeetingMetadata.self, forKey: .metadata)
        sourceLocale = try container.decodeIfPresent(
            MeetingSourceLocale.self,
            forKey: .sourceLocale
        )
        transcriptionPlan = try container.decodeIfPresent(
            TranscriptionPlan.self,
            forKey: .transcriptionPlan
        )
        unrecordedTracks = try container.decodeIfPresent(
            [MediaAsset.Kind].self,
            forKey: .unrecordedTracks
        ) ?? []
    }
}
