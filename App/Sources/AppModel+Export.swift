import AppKit
import Foundation
import StenoDomain
import StenoExchange
import StenoLibrary
import StenoPipeline
import UniformTypeIdentifiers

/// Markdown-Export eines Meetings.
///
/// Bisher kam man an ein Transkript nur ueber das Dateisystem heran. Der
/// Export nimmt alles mit, was ohne Raten zusammengehoert - Notiz, Berichte,
/// Transkript samt aufgeloesten Namen - und schreibt nichts in die Bibliothek.
@MainActor
extension AppModel {
    func performStereoAudioExport(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        meetingID: MeetingID,
        fileName: String
    ) async {
        guard audioExportActivity == nil else {
            report("Another audio export is already running.")
            return
        }
        let activity = AudioExportActivity(
            meetingID: meetingID,
            fileName: fileName,
            fraction: 0
        )
        audioExportActivity = activity
        defer {
            if audioExportActivity?.id == activity.id {
                audioExportActivity = nil
            }
        }

        do {
            try await stereoAudioExportPerformer(
                microphoneURL,
                systemURL,
                destinationURL
            ) { [weak self] update in
                guard let self,
                      let current = self.audioExportActivity,
                      current.id == activity.id
                else { return }
                self.audioExportActivity = current.withFraction(
                    max(current.fraction, update.fraction)
                )
            }
            try Task.checkCancellation()
            report("Saved \(fileName).", isError: false)
        } catch is CancellationError {
            return
        } catch {
            report(verbatim: AppModel.message(
                "The stereo M4A could not be saved. The originals remain in Steno.",
                error
            ))
        }
    }

    func exportStereoAudio(
        microphone: MediaAsset,
        system: MediaAsset,
        of meetingID: MeetingID
    ) async {
        guard let runtime else { return }
        guard let meeting = await meeting(meetingID) else {
            report("This meeting no longer exists.")
            return
        }
        let layout = await runtime.library.layout
        let microphoneURL = layout.mediaFile(
            meetingID,
            fileName: microphone.fileName
        )
        let systemURL = layout.mediaFile(meetingID, fileName: system.fileName)
        guard FileManager.default.fileExists(atPath: microphoneURL.path),
              FileManager.default.fileExists(atPath: systemURL.path)
        else {
            report("One of the selected original tracks is no longer available.")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = AudioExportPresentation.stereoFileName(
            for: meeting
        )
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.message =
            "Microphone is left; system audio is right. The originals stay in Steno."
        guard await panel.begin() == .OK, let destinationURL = panel.url else {
            return
        }
        await performStereoAudioExport(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationURL: destinationURL,
            meetingID: meetingID,
            fileName: destinationURL.lastPathComponent
        )
    }

    /// Baut das Dokument. Getrennt vom Speichern, damit der Aufrufer den
    /// Ablageort erst erfragt, wenn es wirklich etwas zu speichern gibt.
    func exportMarkdown(for meetingID: MeetingID) async -> (name: String, text: String)? {
        guard let runtime else { return nil }
        guard let meeting = await meeting(meetingID) else {
            report("This meeting no longer exists.")
            return nil
        }
        let revision = await transcript(for: meetingID)
        let review = await loadReviewData(meetingID: meetingID, revision: revision)
        let notes = await notes(for: meetingID)
        let reports = await reports(for: meetingID).map(\.result)

        let persons = (try? await IdentityStore(layout: runtime.library.layout)
            .listPersons()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0) })

        var names: [SpeakerReference: String] = [:]
        for person in persons {
            names[.person(person.id)] = person.displayName
        }
        // Cluster bekommen ihren Namen nur, wenn er bestaetigt ist. Ein
        // Vorschlag ist kein Name, und in einem Dokument, das jemand
        // weitergibt, waere er nicht mehr als solcher erkennbar.
        for cluster in review?.clusters ?? [] {
            guard case .confirmed(let personID) = cluster.reviewState,
                  let person = byID[personID]
            else { continue }
            names[.cluster(runID: cluster.runID, clusterID: cluster.clusterID)] =
                person.displayName
            for fragment in cluster.mergedFrom {
                names[.cluster(runID: cluster.runID, clusterID: fragment)] =
                    person.displayName
            }
        }

        // Dieselbe Person kann in beiden Listen stehen (still ergaenzt, spaeter
        // als Sprecherin bestaetigt). In einem Dokument, das jemand
        // weitergibt, stuende ihr Name dann zweimal.
        var seen: Set<PersonID> = []
        let participants = (meeting.participantIDs + meeting.additionalParticipantIDs)
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0]?.displayName }

        let text = MeetingMarkdown.render(MeetingMarkdown.Input(
            meeting: meeting,
            revision: revision,
            authorLine: OperatorProfile.shared.authorLine,
            speakerNames: names,
            participants: participants,
            notes: notes,
            reports: reports
        ))
        return (MeetingMarkdown.fileName(for: meeting), text)
    }

    /// Lesbare Originalspuren und, bei einem eindeutigen Paar, ein gemeinsamer
    /// Stereoexport. Fehlende Dateien werden nie als Auswahl angeboten.
    func audioExportOptions(for meetingID: MeetingID) async -> [AudioExportOption] {
        guard let runtime else { return [] }
        let assets = (try? await runtime.library.listMediaAssets(meetingID: meetingID)) ?? []
        let layout = await runtime.library.layout
        return await AudioExportPresentation.options(
            for: assets,
            resolvingURLWith: { asset in
                layout.mediaFile(meetingID, fileName: asset.fileName)
            }
        )
    }

    /// Kopiert eine Originalspur heraus. Bewusst kopieren und nicht
    /// konvertieren: das Original ist die Referenz, an der jede Zeitmarke
    /// haengt, und es verlaesst die Bibliothek unveraendert.
    func exportAudioTrack(_ asset: MediaAsset, of meetingID: MeetingID) async {
        guard let runtime else { return }
        guard let meeting = await meeting(meetingID) else { return }
        let source = await runtime.library.layout.mediaFile(
            meetingID,
            fileName: asset.fileName
        )
        let stem = MeetingMarkdown.fileName(for: meeting)
            .replacingOccurrences(of: ".md", with: "")
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "\(stem) - \(ChannelLabel.trackName(asset.kind.rawValue))"
            + ".\(source.pathExtension)"
        panel.canCreateDirectories = true
        panel.message = "Save a copy of this original track."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: source, to: url)
            report("Saved \(url.lastPathComponent).", isError: false)
        } catch {
            report(verbatim: AppModel.message("The track could not be saved.", error))
        }
    }

    /// Fragt den Ablageort und schreibt. Der Speicherdialog gehoert hierher
    /// und nicht in die Ansicht, damit der Weg vom Menue und aus dem
    /// Kontextmenue derselbe ist.
    func exportMeetingToFile(_ meetingID: MeetingID) async {
        guard let document = await exportMarkdown(for: meetingID) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.message = "Save this meeting as Markdown."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            try Data(document.text.utf8).write(to: url, options: .atomic)
            report("Saved \(url.lastPathComponent).", isError: false)
        } catch {
            report(verbatim: AppModel.message("The file could not be written.", error))
        }
    }
}

struct AudioExportActivity: Equatable, Identifiable {
    let id: UUID
    let meetingID: MeetingID
    let fileName: String
    let fraction: Double

    init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        fileName: String,
        fraction: Double
    ) {
        self.id = id
        self.meetingID = meetingID
        self.fileName = fileName
        self.fraction = fraction
    }

    func withFraction(_ fraction: Double) -> AudioExportActivity {
        AudioExportActivity(
            id: id,
            meetingID: meetingID,
            fileName: fileName,
            fraction: min(1, max(0, fraction))
        )
    }
}

// MARK: - Obsidian vault export
//
// One-way, non-destructive mirror of meetings into a user-chosen Obsidian
// vault folder (parity with legacy app/obsidian-sync.js). Nothing is ever
// read back from the vault and nothing in the library can be touched by a
// vault edit or deletion.

/// UserDefaults keys for the Obsidian sync settings and status line.
enum ObsidianSyncPreferences {
    static let enabledKey = "steno.obsidian.enabled"
    static let vaultPathKey = "steno.obsidian.vaultPath"
    static let lastSyncSummaryKey = "steno.obsidian.lastSync"
}

@MainActor
extension AppModel {
    /// Mirrors every meeting into the configured vault. Runs only after the
    /// approval dialog; without the toggle or a chosen folder it reports
    /// instead of silently doing nothing.
    func syncObsidianVault() async {
        guard UserDefaults.standard.bool(forKey: ObsidianSyncPreferences.enabledKey) else {
            report("Obsidian export is turned off in Settings.")
            return
        }
        guard let vaultURL = Self.obsidianVaultURL else {
            report("Choose an Obsidian vault folder in Settings first.")
            return
        }
        guard let runtime else { return }
        let meetings = (try? await runtime.library.listMeetings()) ?? []
        await exportMeetingsToObsidianVault(meetings, into: vaultURL)
    }

    /// "Export now" for one meeting from the detail context menu.
    func exportMeetingToObsidianVault(_ meetingID: MeetingID) async {
        guard let vaultURL = Self.obsidianVaultURL else {
            report("Choose an Obsidian vault folder in Settings first.")
            return
        }
        guard let meeting = await meeting(meetingID) else {
            report("This meeting no longer exists.")
            return
        }
        await exportMeetingsToObsidianVault([meeting], into: vaultURL)
    }

    private func exportMeetingsToObsidianVault(
        _ meetings: [Meeting],
        into vaultURL: URL
    ) async {
        // Approval gate: no byte reaches the vault before the user has seen
        // the plaintext warning naming the exact target folder.
        var gate = ObsidianExportApprovalGate()
        gate.requestExport(into: vaultURL.path)
        guard gate.resolveApproval(approveObsidianWrite(into: vaultURL)),
              let approvedPath = gate.beginExport()
        else { return }

        var documents: [ObsidianVaultDocument] = []
        for meeting in meetings {
            if let document = await obsidianVaultDocument(for: meeting) {
                documents.append(document)
            }
        }
        let summary = ObsidianExporter.sync(
            documents,
            into: ObsidianVault(baseURL: URL(fileURLWithPath: approvedPath))
        )

        if summary.failures.isEmpty {
            let detail = summary.isDiffEmpty
                ? "already up to date"
                : "\(summary.written) written, \(summary.updated) updated"
            let line = "Obsidian: \(meetings.count) meetings (\(detail))."
            UserDefaults.standard.set(
                line,
                forKey: ObsidianSyncPreferences.lastSyncSummaryKey
            )
            report(verbatim: line, isError: false)
        } else {
            let line = "Obsidian export failed for "
                + summary.failures.joined(separator: ", ")
                + "."
            UserDefaults.standard.set(
                line,
                forKey: ObsidianSyncPreferences.lastSyncSummaryKey
            )
            report(verbatim: line)
        }
    }

    private func obsidianVaultDocument(for meeting: Meeting) async -> ObsidianVaultDocument? {
        guard let document = await exportMarkdown(for: meeting.id) else { return nil }
        guard let runtime else { return nil }
        let persons = (try? await IdentityStore(layout: runtime.library.layout)
            .listPersons()) ?? []
        let byID = Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0) })
        var seen: Set<PersonID> = []
        let participants = (meeting.participantIDs + meeting.additionalParticipantIDs)
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0]?.displayName }
        return ObsidianVaultDocument(
            meetingID: meeting.id.rawValue,
            title: meeting.title,
            createdAt: meeting.createdAt,
            status: meeting.status.rawValue,
            participants: participants,
            bodyMarkdown: document.text
        )
    }

    /// The approval dialog itself. The warning text is deliberately plain
    /// about the consequence: these files are unencrypted Markdown in a
    /// folder the user may not control exclusively.
    private func approveObsidianWrite(into vaultURL: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Export to Obsidian?"
        alert.informativeText =
            "Steno will write meeting notes as plain Markdown files into "
            + vaultURL.path
            + ". Anyone with folder access can read them."
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    static var obsidianVaultURL: URL? {
        guard let path = UserDefaults.standard.string(
            forKey: ObsidianSyncPreferences.vaultPathKey
        ), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - PDF export & Copy-notes
//
// Parity with legacy notesPdf.ts/notesCopy.ts. Both actions feed from the
// exact same source as the individual Markdown file export
// (AppModel.exportMarkdown), so the clipboard, the .md file and the rendered
// PDF can never carry different content.

@MainActor
extension AppModel {
    /// Places the individual meeting export (the full Markdown document) on
    /// the pasteboard. Returns the copied text so the view can flash its
    /// confirmation; nil means there was nothing to copy.
    @discardableResult
    func copyNotesToPasteboard(for meetingID: MeetingID) async -> String? {
        guard let document = await exportMarkdown(for: meetingID) else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(document.text, forType: .string)
        return document.text
    }

    /// Renders the same Markdown document as a simple print-quality PDF into
    /// a temporary file and opens the system share menu on it.
    func shareNotesAsPDF(for meetingID: MeetingID) async {
        guard let document = await exportMarkdown(for: meetingID) else { return }
        let url: URL
        do {
            url = try PDFExportPresentation.writeTemporaryPDF(
                markdown: document.text,
                fileName: document.name
            )
        } catch {
            report(verbatim: AppModel.message("The PDF could not be rendered.", error))
            return
        }
        guard PDFExportPresentation.presentShareSheet(for: url, anchoredTo: nil) else {
            report("No window is available to show the share menu.")
            return
        }
    }
}

// MARK: - Bulk export (all meetings)
//
// Parity with the legacy "export all" command (tests/test_export_all.py):
// every meeting as Markdown into a chosen directory, or one CSV file with a
// fixed column set. Both refuse to write anywhere inside the library so an
// exported copy can never be mistaken for library data.

/// Result of a bulk export run: the number of meetings actually written, or
/// a user-facing error message.
enum BulkExportOutcome: Equatable {
    case success(count: Int)
    case failure(message: String)
}

@MainActor
extension AppModel {
    /// Writes one Markdown file per meeting (the exact same document as the
    /// single-meeting export) into `directory`. Duplicate titles are
    /// disambiguated with `_2`, `_3`, ... suffixes, like the legacy CLI.
    func exportAllMeetingsAsMarkdown(to directory: URL) async -> BulkExportOutcome {
        guard let rejection = BulkExportPathSafety.rejectionReason(
            targetDirectory: directory,
            libraryDirectory: resolvedLibraryURL
        ) else {
            return await writeBulkMarkdown(to: directory)
        }
        return .failure(message: rejection)
    }

    private func writeBulkMarkdown(to directory: URL) async -> BulkExportOutcome {
        guard let runtime else { return .failure(message: "No library is open.") }
        let meetings = (try? await runtime.library.listMeetings()) ?? []
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            } catch {
                return .failure(
                    message: AppModel.message("The folder could not be created.", error)
                )
            }
        }

        var usedFileNames: Set<String> = []
        var written = 0
        for meeting in meetings {
            guard let document = await exportMarkdown(for: meeting.id) else { continue }
            var fileName = document.name
            var index = 2
            while usedFileNames.contains(fileName) {
                let stem = (document.name as NSString).deletingPathExtension
                fileName = "\(stem)_\(index).md"
                index += 1
            }
            usedFileNames.insert(fileName)
            do {
                try Data(document.text.utf8).write(
                    to: directory.appendingPathComponent(fileName),
                    options: .atomic
                )
                written += 1
            } catch {
                // One unreadable meeting must not abort the whole run; the
                // count only reports what really landed on disk.
                continue
            }
        }
        return .success(count: written)
    }

    /// Writes all meetings as one CSV file. The destination's parent
    /// directory is subject to the same containment rule as the Markdown
    /// directory pick.
    func exportAllMeetingsAsCSV(to fileURL: URL) async -> BulkExportOutcome {
        guard let rejection = BulkExportPathSafety.rejectionReason(
            targetDirectory: fileURL.deletingLastPathComponent(),
            libraryDirectory: resolvedLibraryURL
        ) else {
            return await writeBulkCSV(to: fileURL)
        }
        return .failure(message: rejection)
    }

    private func writeBulkCSV(to fileURL: URL) async -> BulkExportOutcome {
        guard let runtime else { return .failure(message: "No library is open.") }
        let meetings = ((try? await runtime.library.listMeetings()) ?? [])
            .sorted { $0.createdAt < $1.createdAt }
        var rows: [BulkExportCSV.MeetingRow] = []
        for meeting in meetings {
            rows.append(await bulkCSVRow(for: meeting))
        }
        do {
            try Data(BulkExportCSV.build(rows).utf8).write(to: fileURL, options: .atomic)
        } catch {
            return .failure(message: AppModel.message("The CSV could not be written.", error))
        }
        return .success(count: rows.count)
    }

    /// Flattens one meeting into the CSV row shape: title, ISO date,
    /// duration from the longest media asset, folder name, attendee display
    /// names, latest report text as the summary, and the transcript text.
    private func bulkCSVRow(for meeting: Meeting) async -> BulkExportCSV.MeetingRow {
        let formatter = ISO8601DateFormatter()
        var folders = meeting.metadata?.legacyFolders ?? []
        if let folderID = meeting.folderID,
           let folderStore,
           let folder = try? await folderStore.folder(folderID)
        {
            folders.append(folder.name)
        }

        var durationSeconds: Int?
        if let runtime,
           let assets = try? await runtime.library.listMediaAssets(meetingID: meeting.id) {
            durationSeconds = assets.map(\.duration).max().map(Int.init)
        }

        let revision = await transcript(for: meeting.id)
        var transcriptText = ""
        if let revision {
            transcriptText = revision.turns.compactMap { turn in
                turn.segments
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }

        // The most recent report stands in for the legacy summary column.
        let reports = await reports(for: meeting.id)
        let summary = reports.last.map { $0.result.markdown } ?? ""

        var attendees: [String] = []
        if let runtime,
           let persons = try? await IdentityStore(layout: runtime.library.layout)
               .listPersons()
        {
            let byID = Dictionary(uniqueKeysWithValues: persons.map { ($0.id, $0) })
            attendees = (meeting.participantIDs + meeting.additionalParticipantIDs)
                .compactMap { byID[$0]?.displayName }
        }

        return BulkExportCSV.MeetingRow(
            title: meeting.title,
            date: formatter.string(from: meeting.createdAt),
            durationSeconds: durationSeconds,
            folders: folders,
            attendees: attendees,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            transcript: transcriptText
        )
    }
}
