import Foundation
import StenoDomain
import StenoPipeline

/// How a recording that is missing a track describes itself in the interface.
///
/// Kept out of the view: this is the wording that tells someone a side of the
/// conversation was never recorded, and it has to be checkable on its own.
enum MeetingCompleteness {
    /// Names the tracks this recording never got. Nil for a complete
    /// recording, so nothing is added where it is used.
    static func missingTracksWord(_ kinds: [MediaAsset.Kind]) -> String? {
        guard !kinds.isEmpty else { return nil }
        let names = kinds
            .sorted { $0.rawValue < $1.rawValue }
            .map {
                $0 == .micTrack
                    ? String(localized: "Microphone")
                    : String(localized: "system audio")
            }
            .joined(separator: String(localized: " and "))
        return String(localized: "\(names) missing")
    }

    /// What the minutes have to admit when a track was never recorded.
    ///
    /// Stated by the app, not by the text model: a model can be asked to
    /// mention a missing track and simply not do it, and minutes that quietly
    /// leave out one side of a conversation read exactly like complete ones.
    static func reportCaveat(_ kinds: [MediaAsset.Kind]) -> String? {
        guard !kinds.isEmpty else { return nil }
        let missesMicrophone = kinds.contains(.micTrack)
        let side = missesMicrophone
            ? String(localized: "Microphone track")
            : String(localized: "System audio track")
        let whose = missesMicrophone
            ? String(localized: "what you said yourself")
            : String(localized: "what the other participants said")
        return String(
            localized: "\(side) was not recorded, so these minutes do not cover \(whose)."
        )
    }

    /// The minutes as text for the clipboard.
    ///
    /// Uses the same wording the exported document carries, because copied
    /// minutes leave the app exactly like exported ones do and the label on
    /// screen does not travel with them.
    static func minutesForCopying(
        _ markdown: String,
        unrecordedTracks: [MediaAsset.Kind]
    ) -> String {
        guard let note = MeetingMarkdown.incompleteRecordingNote(
            unrecordedTracks
        ) else {
            return markdown
        }
        return "\(note)\n\n\(markdown)"
    }
}
