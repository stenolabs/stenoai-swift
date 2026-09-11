import Foundation
import StenoDomain

/// Baut aus einem Meeting ein Markdown-Dokument zum Weitergeben.
///
/// Bewusst rein und ohne Dateizugriff: der Aufrufer entscheidet, was er
/// hineinreicht und wohin das Ergebnis geht. Nichts hier faellt zurueck auf
/// "irgendetwas" - fehlt ein Teil, steht er nicht da, statt geraten zu werden.
public enum MeetingMarkdown {
    public struct Input: Sendable {
        public let meeting: Meeting
        public let revision: TranscriptRevision?
        /// Wer das Protokoll erstellt. Ohne Eintrag steht im Kopf keine Zeile.
        public let authorLine: String?
        /// Namensaufloesung fuer die Sprecher. Ohne sie stehen die technischen
        /// Bezeichnungen da - das ist ehrlicher als ein geratener Name.
        public let speakerNames: [SpeakerReference: String]
        public let participants: [String]
        public let notes: String?
        public let reports: [TemplateResult]

        public init(
            meeting: Meeting,
            revision: TranscriptRevision?,
            authorLine: String? = nil,
            speakerNames: [SpeakerReference: String] = [:],
            participants: [String] = [],
            notes: String? = nil,
            reports: [TemplateResult] = []
        ) {
            self.meeting = meeting
            self.revision = revision
            self.authorLine = authorLine
            self.speakerNames = speakerNames
            self.participants = participants
            self.notes = notes
            self.reports = reports
        }
    }

    /// Der Kopf des Dokuments: Titel und, wenn einer hinterlegt ist, der
    /// Verfasser. Ohne Verfasser bleibt der Kopf so, wie er vorher war -
    /// eine leere Zeile "Author:" waere schlechter als keine.
    public static func header(title: String, authorLine: String?) -> String {
        var lines = ["# \(title)"]
        let author = authorLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let author, !author.isEmpty {
            lines.append("")
            lines.append("**Author:** \(author)")
        }
        return lines.joined(separator: "\n")
    }


    /// States that this recording is missing a track.
    ///
    /// Placed in the document itself, not only in the app: an exported or
    /// copied set of minutes travels without the interface around it, and
    /// minutes that quietly leave out one side of a conversation read exactly
    /// like complete ones.
    public static func incompleteRecordingNote(
        _ unrecordedTracks: [MediaAsset.Kind]
    ) -> String? {
        guard !unrecordedTracks.isEmpty else { return nil }
        let missing = unrecordedTracks
            .sorted { $0.rawValue < $1.rawValue }
            .map { $0 == .micTrack ? "the microphone" : "the system audio" }
            .joined(separator: " and ")
        return "> **Incomplete recording:** \(missing) was not recorded, "
            + "so anything said on that side is not part of this document."
    }

    public static func render(
        _ input: Input,
        calendar: Calendar = .current
    ) -> String {
        var lines: [String] = []
        lines.append(header(title: input.meeting.title, authorLine: input.authorLine))
        lines.append("")
        lines.append(dateLine(input.meeting.createdAt, calendar: calendar))
        if let note = incompleteRecordingNote(input.meeting.unrecordedTracks) {
            lines.append("")
            lines.append(note)
        }
        if !input.participants.isEmpty {
            lines.append("")
            lines.append("**Participants:** \(input.participants.joined(separator: ", "))")
        }

        if let notes = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            lines.append("")
            lines.append("## Notes")
            lines.append("")
            lines.append(notes)
        }

        for report in input.reports {
            lines.append("")
            lines.append("## \(report.template.name)")
            lines.append("")
            lines.append(report.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        lines.append("")
        lines.append("## Transcript")
        lines.append("")
        if let revision = input.revision, !revision.turns.isEmpty {
            let readable = transcript(revision, names: input.speakerNames)
            lines.append(contentsOf: readable)
            let stamped = timestampedTranscript(revision, names: input.speakerNames)
            if stamped != readable {
                lines.append("")
                lines.append("## Timestamped transcript")
                lines.append("")
                lines.append(contentsOf: stamped)
            }
        } else {
            // Ein leerer Abschnitt waere schlimmer als ein Satz, der sagt,
            // warum er leer ist.
            lines.append("_No transcript yet._")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static let coalesceMaxGap: TimeInterval = 2.5
    private static let coalesceMaxSpan: TimeInterval = 20
    private static let coalesceMaxCharacters = 400

    private static func transcript(
        _ revision: TranscriptRevision,
        names: [SpeakerReference: String]
    ) -> [String] {
        struct Row {
            var start: TimeInterval
            var end: TimeInterval
            var speaker: String
            var texts: [String]
            var characterCount: Int { texts.joined(separator: " ").count }
        }
        var rows: [Row] = []
        for turn in revision.turns {
            let text = turnText(turn)
            guard !text.isEmpty else { continue }
            let speaker = turn.speaker.map { reference in
                speakerName(for: reference, names: names)
            } ?? "Unknown speaker"
            if let last = rows.indices.last,
               rows[last].speaker == speaker,
               turn.start <= rows[last].end + coalesceMaxGap,
               (turn.end - rows[last].start) <= coalesceMaxSpan,
               rows[last].characterCount + 1 + text.count <= coalesceMaxCharacters
            {
                rows[last].texts.append(text)
                rows[last].end = max(rows[last].end, turn.end)
            } else {
                rows.append(Row(
                    start: turn.start,
                    end: turn.end,
                    speaker: speaker,
                    texts: [text]
                ))
            }
        }
        var lines: [String] = []
        for row in rows {
            lines.append(
                "**[\(timecode(row.start))] \(row.speaker):** \(row.texts.joined(separator: " "))"
            )
            lines.append("")
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func timestampedTranscript(
        _ revision: TranscriptRevision,
        names: [SpeakerReference: String]
    ) -> [String] {
        var lines: [String] = []
        for turn in revision.turns {
            let text = turnText(turn)
            guard !text.isEmpty else { continue }
            let speaker = turn.speaker.map { reference in
                speakerName(for: reference, names: names)
            } ?? "Unknown speaker"
            lines.append("**[\(timecode(turn.start))] \(speaker):** \(text)")
            lines.append("")
        }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func turnText(_ turn: TranscriptTurn) -> String {
        turn.segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Ohne aufgeloesten Namen wird die technische Herkunft gezeigt, nicht
    /// geraten. Ein falscher Name in einem Dokument, das jemand weitergibt,
    /// ist der teuerste Fehler dieser Kette.
    private static func fallbackName(_ reference: SpeakerReference) -> String {
        switch reference {
        case .channel(let name): ChannelLabel.speakerLabel(name)
        case .cluster(_, let clusterID): "Speaker \(clusterID)"
        case .person: "Unknown speaker"
        case .importedTextLabel(let imported):
            imported.wasConfirmedAtSource && !imported.text.isEmpty
                ? imported.text
                : "Unknown speaker"
        }
    }

    private static func speakerName(
        for reference: SpeakerReference,
        names: [SpeakerReference: String]
    ) -> String {
        if case .importedTextLabel = reference {
            return fallbackName(reference)
        }
        return names[reference] ?? fallbackName(reference)
    }

    private static func dateLine(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // `formatter.calendar` alone does not pin the zone: without this,
        // exports render in the machine timezone and shift by locale.
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "*\(formatter.string(from: date))*"
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }

    /// Dateiname aus dem Titel: alles, was ein Dateisystem oder ein spaeterer
    /// Leser missversteht, faellt weg. Ein leerer Rest wird nicht zu einer
    /// namenlosen Datei, sondern zu "meeting".
    public static func fileName(for meeting: Meeting, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let slug = meeting.title
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let safe = slug.isEmpty ? "meeting" : String(slug.prefix(80))
        return "\(formatter.string(from: meeting.createdAt)) \(safe).md"
    }
}
