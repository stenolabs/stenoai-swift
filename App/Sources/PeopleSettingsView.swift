import AVFoundation
import StenoDomain
import StenoIdentity
import StenoLibrary
import StenoPipeline
import SwiftUI
import UniformTypeIdentifiers

/// Personenverwaltung in den Einstellungen.
///
/// Sie ist der einzige Ort, an dem sichtbar wird, worauf die Wiedererkennung
/// tatsaechlich laeuft - und der einzige, an dem sich eine falsche Stimmprobe
/// oder ein falsches Hard Negative korrigieren laesst. Korrigiert wird durch
/// Ausnehmen, nicht durch Loeschen: die Probe bleibt gespeichert und zaehlt
/// nur nicht mehr, damit eine Fehleinschaetzung umkehrbar bleibt.
struct PeopleSettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [AppModel.PersonEntry] = []
    @State private var isLoading = true
    @State private var expanded: Set<PersonID> = []
    @State private var renaming: AppModel.PersonEntry?
    @State private var deleting: AppModel.PersonEntry?
    @State private var merging: AppModel.PersonEntry?
    @State private var undoable: DeletedPerson?
    @State private var isRestoring = false
    // The operator's own person ("Me"), plus the cross-meeting suggestions
    // that recognition scored past the possible gate but no human confirmed.
    @State private var selfPersonID: PersonID?
    @State private var unconfirmedMatches: [PersonID: [PersonMatch]] = [:]
    @State private var isScanningMatches = false
    @State private var enrolling: AppModel.PersonEntry?

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let undoable {
                undoBar(undoable)
            }
            if let error = model.peopleError {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Steno.Colors.error)
                    Spacer()
                    Button("Dismiss") { model.peopleError = nil }
                        .buttonStyle(.link)
                }
                .padding(Steno.Space.m)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 420,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .task { await reload() }
        .onDisappear { model.stopSamplePlayback() }
        .sheet(item: $enrolling) { entry in
            VoiceEnrollmentSheet(entry: entry) {
                await reload()
            }
        }
        .sheet(item: $renaming) { entry in
            RenamePersonSheet(entry: entry) { name in
                let ok = await model.renamePerson(entry.id, to: name)
                if ok {
                    await reload()
                    renaming = nil
                }
                return ok
            }
        }
        .sheet(item: $merging) { entry in
            MergePersonSheet(source: entry, candidates: entries.filter { $0.id != entry.id }) { targetID in
                let ok = await model.mergePerson(entry.id, into: targetID)
                if ok {
                    // Erst die Liste, dann das Sheet: sonst ist die
                    // aufgeloeste Person kurz weiter sichtbar, mit Knoepfen,
                    // die auf ein Profil zeigen, das es nicht mehr gibt.
                    await reload()
                    merging = nil
                }
                return ok
            }
        }
        .confirmationDialog(
            deleting.map { "Delete \($0.person.displayName)?" } ?? "",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let target = deleting else { return }
                Task {
                    let snapshot = await model.deletePerson(target.id)
                    deleting = nil
                    // Erst neu laden, dann den Ruecknahme-Balken zeigen: sonst
                    // steht er neben der Zeile, die er gerade rueckgaengig
                    // machen soll, samt funktionierender Knoepfe.
                    await reload()
                    undoable = snapshot
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            // Die Reichweite zu nennen ist der ganze Zweck des Dialogs: sie
            // wird nicht kleiner, weil er aus den Einstellungen kommt.
            Text(
                "This removes them from every meeting's speaker suggestions and deletes their voice profile."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            Text("People")
                .font(.headline)
            Text(
                "Everyone Steno has learned to recognise by voice. Names come from confirming a speaker in a meeting."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Steno.Space.m)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No people yet",
                systemImage: "person.2",
                description: Text(
                    "Confirm a speaker in a meeting and they will appear here."
                )
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        personRow(entry)
                        Divider()
                    }
                }
            }
        }
    }

    private func personRow(_ entry: AppModel.PersonEntry) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                Circle()
                    .fill(Steno.Colors.speaker(for: entry.id))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Steno.Space.xs) {
                        Text(entry.person.displayName)
                        if entry.id == selfPersonID {
                            Text("You")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Steno.Colors.confirmed.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(Steno.Colors.confirmed)
                        }
                    }
                    Text(subtitle(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actions(entry)
            }
            if !entry.samples.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expanded.contains(entry.id) },
                        set: { isOpen in
                            if isOpen {
                                expanded.insert(entry.id)
                            } else {
                                expanded.remove(entry.id)
                            }
                        }
                    )
                ) {
                    sampleList(entry)
                    matchSection(entry)
                } label: {
                    Text("Voice evidence")
                        .font(.caption)
                }
                .font(.caption)
            }
        }
        .padding(Steno.Space.m)
    }

    private func actions(_ entry: AppModel.PersonEntry) -> some View {
        HStack(spacing: Steno.Space.s) {
            Menu {
                Button("Enroll voice sample…") { enrolling = entry }
                if entry.id == selfPersonID {
                    Button("This is no longer me") {
                        try? DefaultSelfVoiceprintStore().saveSelfPersonID(nil)
                        selfPersonID = nil
                    }
                } else {
                    Button("This is me") {
                        try? DefaultSelfVoiceprintStore().saveSelfPersonID(entry.id)
                        selfPersonID = entry.id
                    }
                }
                Divider()
                Button("Rename…") { renaming = entry }
                Button("Merge into another person…") { merging = entry }
                    .disabled(entries.count < 2)
                Divider()
                Button("Delete…", role: .destructive) { deleting = entry }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for \(entry.person.displayName)")
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func sampleList(_ entry: AppModel.PersonEntry) -> some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            ForEach(entry.prototypes) { sample in
                SampleDetailRow(sample: sample) { excluded in
                    _ = await model.setSampleExcluded(sample, excluded: excluded)
                    await reload()
                }
            }
            if entry.prototypes.isEmpty {
                Text("No voice samples yet - Steno cannot recognise them automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.hardNegatives.isEmpty {
                negativeSection(entry)
            }
        }
        .padding(.top, Steno.Space.xs)
    }

    /// Gegen-Evidenz steht getrennt und zugeklappt. Sie ist die gefaehrlichere
    /// Richtung: ein falscher Eintrag unterdrueckt eine echte Erkennung
    /// dauerhaft, auch in Meetings, die damit nichts zu tun haben - und nichts
    /// im spaeteren Fehlverhalten zeigt zurueck auf die Ursache.
    private func negativeSection(_ entry: AppModel.PersonEntry) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Text(
                    "Clips you marked as someone else. Steno uses them to avoid future mix-ups - a wrong entry here blocks recognition for good, even in unrelated meetings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(entry.hardNegatives) { sample in
                    SampleDetailRow(sample: sample) { excluded in
                        _ = await model.setSampleExcluded(sample, excluded: excluded)
                        await reload()
                    }
                }
            }
            .padding(.top, Steno.Space.xs)
        } label: {
            Text("Confirmed not \(entry.person.displayName) (\(entry.hardNegatives.count))")
                .font(.caption)
        }
        .padding(.top, Steno.Space.xs)
    }

    private func undoBar(_ snapshot: DeletedPerson) -> some View {
        HStack(spacing: Steno.Space.s) {
            Text("Deleted \(snapshot.person.displayName).")
                .font(.callout)
            Spacer()
            Button("Undo") {
                guard !isRestoring else { return }
                isRestoring = true
                // Der Schnappschuss verschwindet sofort: ein zweiter Klick
                // wuerde dieselbe Person ein zweites Mal einsetzen wollen und
                // an der Namensprueffung mit einem Fehler scheitern, der wie
                // ein echtes Problem aussaehe.
                undoable = nil
                Task {
                    if await model.restorePerson(snapshot) {
                        await reload()
                    } else {
                        undoable = snapshot
                    }
                    isRestoring = false
                }
            }
            .disabled(isRestoring)
            Button {
                undoable = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(Steno.Space.m)
        .background(.quaternary)
    }

    private func subtitle(_ entry: AppModel.PersonEntry) -> String {
        var parts: [String] = []
        let active = entry.activePrototypeCount
        let total = entry.prototypes.count
        if total == 0 {
            parts.append(String(localized: "No voice samples yet"))
        } else if active == total {
            parts.append(String(localized: "Voice samples: \(total)"))
        } else {
            parts.append(String(localized: "\(active) of \(total) voice samples in use"))
        }
        if let organization = entry.person.organization {
            parts.append(organization)
        }
        if let email = entry.person.email {
            parts.append(email)
        }
        return parts.joined(separator: "  ·  ")
    }

    private func reload() async {
        entries = await model.loadPeople()
        isLoading = false
        // Aufgeklappte Zeilen ueberleben nur, solange es die Person gibt.
        let ids = Set(entries.map(\.id))
        expanded = expanded.intersection(ids)
        await loadIdentityExtras()
    }

    /// Laedt die Selbst-Bindung und scannt alle Meetings nach unbestaetigten
    /// Treffern. Der Scan laeuft bewusst NACH dem schnellen Listenaufbau: die
    /// Personenverwaltung bleibt bedienbar, waehrend die Review-Staende
    /// hereinkommen. Run-Provenienz und isActive-Filterung liegen im
    /// Assembler bzw. Scanner; hier wird nichts gefiltert, nur angezeigt.
    private func loadIdentityExtras() async {
        let store = DefaultSelfVoiceprintStore()
        selfPersonID = try? store.loadSelfPersonID()

        guard let runtime = model.runtime else {
            unconfirmedMatches = [:]
            return
        }
        isScanningMatches = true
        defer { isScanningMatches = false }
        do {
            let library = runtime.library
            let meetings = (try? await library.listMeetings()) ?? []
            var reviews: [MeetingReviewData] = []
            var clustersByMeeting: [CrossMeetingSuggestionScanner.MeetingClusters] = []
            for meeting in meetings where !meeting.isDemo {
                guard
                    let review = try? await MeetingReviewAssembler.load(
                        library: library,
                        meetingID: meeting.id
                    ),
                    !review.clusters.isEmpty
                else { continue }
                reviews.append(review)
                clustersByMeeting.append(CrossMeetingSuggestionScanner.MeetingClusters(
                    meetingID: meeting.id,
                    clusters: review.clusters
                ))
            }
            guard !clustersByMeeting.isEmpty else {
                unconfirmedMatches = [:]
                return
            }
            let identityStore = try IdentityStore(layout: await library.layout)
            let persons = try await identityStore.listPersons()
            let suggestionsByID = Dictionary(
                grouping: CrossMeetingSuggestionScanner.suggestions(
                    clustersByMeeting: clustersByMeeting,
                    people: persons
                ),
                by: \.personID
            )

            var loaded: [PersonID: [PersonMatch]] = [:]
            for (personID, suggestions) in suggestionsByID {
                var matches: [PersonMatch] = []
                for suggestion in suggestions {
                    guard let review = reviews.first(where: {
                        $0.runID == suggestion.runID
                            && $0.clusters.contains(where: {
                                $0.channel == suggestion.cluster.channel
                                    && $0.clusterID == suggestion.cluster.clusterID
                            })
                    }) else { continue }
                    let title = meetings.first(where: { $0.id == suggestion.meetingID })?
                        .title
                    // Zitatproben kommen aus der aktuellen Revision des
                    // Meetings - ohne Revision gibt es die Zeile ohne Play-
                    // knopf, nie mit einer erratenen Zeitangabe.
                    let revision = try? await library.loadCurrentRevision(
                        meetingID: suggestion.meetingID
                    )
                    let samples = revision.map {
                        SpeakerSampleSelector.samples(
                            for: suggestion.cluster,
                            revision: $0,
                            resolutions: review.resolutions
                        )
                    } ?? []
                    matches.append(PersonMatch(
                        suggestion: suggestion,
                        meetingTitle: title,
                        samples: samples,
                        review: review
                    ))
                }
                if !matches.isEmpty {
                    loaded[personID] = matches
                }
            }
            unconfirmedMatches = loaded
        } catch {
            // Ein fehlgeschlagener Scan ist kein Grund, die Verwaltung zu
            // sperren - die Liste bleibt einfach leer.
            unconfirmedMatches = [:]
        }
    }

    @ViewBuilder
    private func matchSection(_ entry: AppModel.PersonEntry) -> some View {
        let matches = unconfirmedMatches[entry.id] ?? []
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: Steno.Space.xs) {
                Text("Possibly also in other meetings (\(matches.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(matches) { match in
                    PersonMatchRow(
                        match: match,
                        personName: entry.person.displayName,
                        confirm: { await confirmMatch($0) },
                        dismiss: { await dismissMatch($0) }
                    )
                }
            }
            .padding(.top, Steno.Space.xs)
        } else if isScanningMatches {
            HStack(spacing: Steno.Space.xs) {
                ProgressView()
                    .controlSize(.mini)
                Text("Scanning other meetings…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, Steno.Space.xs)
        }
    }

    private func confirmMatch(_ match: PersonMatch) async {
        guard let runtime = model.runtime else { return }
        do {
            _ = try await MeetingReviewController(library: runtime.library).perform(
                .confirm(personID: match.suggestion.personID),
                on: match.suggestion.cluster,
                data: match.review,
                meetingID: match.suggestion.meetingID
            )
        } catch {
            model.peopleError = "Confirming this match failed: \(error.localizedDescription)"
            return
        }
        await reload()
    }

    private func dismissMatch(_ match: PersonMatch) async {
        guard let runtime = model.runtime else { return }
        do {
            let store = try IdentityStore(layout: await runtime.library.layout)
            let snapshot = try await store.snapshot()
            var persons = snapshot.persons
            guard
                let index = persons.firstIndex(where: {
                    $0.id == match.suggestion.personID
                })
            else { return }
            // Ausnehmen statt loeschen: das Negative traegt die volle
            // Herkunft des Paares und bleibt im Profil umkehrbar.
            persons[index].hardNegatives.append(
                CrossMeetingSuggestionScanner.dismissalNegative(for: match.suggestion)
            )
            _ = try await store.replacePersons(
                persons,
                expectedRevision: snapshot.revision
            )
        } catch {
            model.peopleError = "Dismissing this match failed: \(error.localizedDescription)"
            return
        }
        await reload()
    }
}

/// Eine einzelne Stimm-Evidenz. Sie sagt, woher sie stammt, ob sie noch zum
/// aktuellen Lauf gehoert und ob sie zaehlt - und bietet einen Abspielknopf
/// nur dann an, wenn der Ausschnitt sicher aufloesbar ist.
private struct SampleDetailRow: View {
    @Environment(AppModel.self) private var model
    let sample: PersonVoiceSample
    let setExcluded: (Bool) async -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
            if sample.playback != nil {
                Button {
                    Task { await model.togglePersonSample(sample) }
                } label: {
                    Image(
                        systemName: isPlaying
                            ? "stop.circle.fill"
                            : "play.circle"
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.isRecording)
                .help(model.isRecording
                    ? "Not while recording - it would be captured into the recording"
                    : (isPlaying ? "Stop" : "Play this voice sample"))
                .accessibilityLabel(
                    isPlaying
                        ? "Stop the voice sample"
                        : "Play the voice sample from \(sample.meetingTitle ?? "a deleted meeting")"
                )
            } else {
                Image(systemName: "speaker.slash")
                    .foregroundStyle(.tertiary)
                    .help("Audio no longer available")
                    .accessibilityLabel("Audio no longer available")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(sample.isExcluded ? .secondary : .primary)
                if sample.isSuperseded || sample.isExcluded {
                    HStack(spacing: Steno.Space.xs) {
                        if sample.isSuperseded {
                            badge("From an older analysis", color: Steno.Colors.uncertain)
                        }
                        if sample.isExcluded {
                            badge("Not used", color: .secondary)
                        }
                    }
                }
            }
            Spacer()
            // Der Wortlaut nennt die Wirkung, nicht die Mechanik: "Exclude"
            // liess offen, wovon - und die Entscheidung "ausnehmen statt
            // loeschen" sah dadurch aus wie ein fehlender Loeschknopf.
            Button(sample.isExcluded ? "Use again" : "Don't use for recognition") {
                Task { await setExcluded(!sample.isExcluded) }
            }
            .controlSize(.small)
            .help(
                sample.isExcluded
                    ? "Count this sample towards recognition again"
                    : "Keep this sample, but stop counting it towards recognition"
            )
        }
    }

    private var isPlaying: Bool { model.playingPersonSampleID == sample.id }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var description: String {
        var parts: [String] = []
        parts.append(sample.meetingTitle ?? "Deleted meeting")
        parts.append(sample.createdAt.formatted(date: .abbreviated, time: .omitted))
        parts.append(ChannelLabel.trackName(sample.channel ?? ""))
        parts.append("\(durationText(sample.speechDurationSeconds)) of speech")
        return parts.joined(separator: "  ·  ")
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total < 60
            ? "\(total)s"
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Ein Fehler, der waehrend eines Sheets auftritt, muss im Sheet stehen. Die
/// Meldungsflaeche der Ansicht liegt dahinter und waere unsichtbar - der
/// Benutzer saehe einen Knopf, der nichts tut.
private struct SheetError: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.peopleError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Steno.Colors.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RenamePersonSheet: View {
    @Environment(AppModel.self) private var model
    let entry: AppModel.PersonEntry
    let save: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Text("Rename \(entry.person.displayName)")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Text("The new name appears in every meeting this person speaks in.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SheetError()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isSaving)
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 360)
        .onAppear {
            name = entry.person.displayName
            // Eine alte Meldung darf nicht wie das Ergebnis dieses Dialogs
            // aussehen.
            model.peopleError = nil
        }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            _ = await save(trimmed)
            isSaving = false
        }
    }
}

/// Zusammenfuehren geht nur in eine Richtung und ist nicht ruecknehmbar. Wer
/// unsicher ist, hoert vorher beide Probenlisten - genau dafuer sind sie da.
private struct MergePersonSheet: View {
    @Environment(AppModel.self) private var model
    let source: AppModel.PersonEntry
    let candidates: [AppModel.PersonEntry]
    let merge: (PersonID) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var targetID: PersonID?
    @State private var isMerging = false

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Text("Merge \(source.person.displayName)")
                .font(.headline)
            Picker("Into", selection: $targetID) {
                Text("Choose a person").tag(PersonID?.none)
                ForEach(candidates) { candidate in
                    Text(label(candidate)).tag(PersonID?.some(candidate.id))
                }
            }
            if let target = candidates.first(where: { $0.id == targetID }) {
                Text(
                    "Voice samples: \(source.prototypes.count). All samples, counter-evidence and meeting appearances move to \(target.person.displayName). \(source.person.displayName) disappears. This can't be undone."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            SheetError()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard let targetID, !isMerging else { return }
                    isMerging = true
                    Task {
                        _ = await merge(targetID)
                        isMerging = false
                    }
                }
                .disabled(targetID == nil || isMerging)
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 400)
        .onAppear { model.peopleError = nil }
    }

    /// Name plus Unterscheidungsmerkmal: zwei gleichnamige Personen sind in
    /// einer wachsenden Stimmdatenbank der Normalfall, und beim Verschmelzen
    /// waere eine Verwechslung nicht mehr zurueckzunehmen.
    private func label(_ entry: AppModel.PersonEntry) -> String {
        let marks = [entry.person.organization, entry.person.email].compactMap { $0 }
        guard !marks.isEmpty else { return entry.person.displayName }
        return "\(entry.person.displayName)  ·  \(marks.joined(separator: "  ·  "))"
    }
}

/// Ein unbestaetigter Treffer in einem anderen Meeting: Herkunft, Zitat und
/// die zwei Ausgaenge - bestaetigen oder dauerhaft unterdruecken.
struct PersonMatch: Identifiable {
    let suggestion: CrossMeetingSuggestion
    let meetingTitle: String?
    let samples: [SpeakerSample]
    /// Der Review-Stand des Meetings, aus dem der Treffer stammt. Nur mit
    /// ihm ist die Bestaetigung ueber denselben Pfad moeglich wie im
    /// Meeting-Detail.
    let review: MeetingReviewData

    var id: String { suggestion.id }
}

private struct PersonMatchRow: View {
    let match: PersonMatch
    let personName: String
    let confirm: (PersonMatch) async -> Void
    let dismiss: (PersonMatch) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Steno.Space.s) {
                Text(match.meetingTitle ?? String(localized: "Deleted meeting"))
                    .font(.caption)
                Text("\(Int(((1 - match.suggestion.distance) * 100).rounded()))% voice match")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Confirm as \(personName)") {
                    Task { await confirm(match) }
                }
                .controlSize(.small)
                Button("Dismiss") {
                    Task { await dismiss(match) }
                }
                .controlSize(.small)
            }
            if !match.samples.isEmpty {
                ForEach(match.samples.prefix(1)) { sample in
                    SampleRow(sample: sample, meetingID: match.suggestion.meetingID)
                }
            } else {
                Text("No quote available for this meeting's current transcript.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Persistenter Zeiger auf die "Ich"-Person. App-Zustand wie die
/// Modellzustimmungen: StenoKit definiert nur den Vertrag, hier steht der
/// Speicherort.
struct DefaultSelfVoiceprintStore: SelfVoiceprintPersonStoring {
    private static let key = "steno.identity.selfPersonID"

    func loadSelfPersonID() throws -> PersonID? {
        guard let raw = UserDefaults.standard.string(forKey: Self.key),
              let uuid = UUID(uuidString: raw) else {
            return nil
        }
        return PersonID(rawValue: uuid)
    }

    func saveSelfPersonID(_ id: PersonID?) throws {
        if let id {
            UserDefaults.standard.set(id.rawValue.uuidString, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}

/// Manuelle Stimmerfassung fuer eine bestehende Person: aufnehmen oder eine
/// Audiodatei importieren, dann rechnet derselbe WeSpeaker-Pfad das
/// Sprachmuster aus, den auch die Meeting-Erkennung benutzt.
private struct VoiceEnrollmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: AppModel.PersonEntry
    let finished: () async -> Void

    @State private var isRecording = false
    @State private var capturedURL: URL?
    @State private var isExtracting = false
    @State private var errorMessage: String?
    @State private var isImportDialogShown = false
    // Der Tap-Callback laeuft auf dem Audiothread; ein @unchecked-Sendable-
    // Behaelter haelt die Datei dort adressierbar, ohne sie herumzureichen.
    private final class RecordingSink: @unchecked Sendable {
        let file: AVAudioFile
        init(file: AVAudioFile) { self.file = file }
        func append(_ buffer: AVAudioPCMBuffer) {
            try? file.write(from: buffer)
        }
    }
    @State private var sink: RecordingSink?
    @State private var engine: AVAudioEngine?

    var body: some View {
        VStack(alignment: .leading, spacing: Steno.Space.m) {
            Text("Enroll a voice sample for \(entry.person.displayName)")
                .font(.headline)
            Text(
                "Speak naturally for at least \(Int(VoiceEnrollmentSelector.minimumSpeechSeconds)) seconds about something. The sample is processed locally and stored only as a numeric voiceprint."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(isRecording ? "Stop recording" : "Record…") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .disabled(isExtracting)
                Button("Import audio file…") { isImportDialogShown = true }
                    .disabled(isRecording || isExtracting)
                if capturedURL != nil || isRecording {
                    Text(isRecording ? "Recording…" : "Sample captured.")
                        .font(.caption)
                        .foregroundStyle(isRecording ? Steno.Colors.recording : .secondary)
                }
            }
            if isExtracting {
                ProgressView {
                    Text("Computing the voiceprint locally…")
                }
                .controlSize(.small)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Steno.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save voiceprint") {
                    Task { await enroll() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capturedURL == nil || isExtracting)
            }
        }
        .padding(Steno.Space.l)
        .frame(width: 420)
        .fileImporter(
            isPresented: $isImportDialogShown,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                capturedURL = url
            }
        }
        .onDisappear {
            if isRecording { stopRecording() }
        }
    }

    private func startRecording() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else {
                Task { @MainActor in
                    errorMessage = "Microphone access was denied."
                }
                return
            }
            Task { @MainActor in
                do {
                    let audioEngine = AVAudioEngine()
                    let input = audioEngine.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0 else {
                        throw EnrollmentCaptureError.noInputFormat
                    }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("enrollment-\(UUID().uuidString).caf")
                    let file = try AVAudioFile(forWriting: url, settings: format.settings)
                    let recordingSink = RecordingSink(file: file)
                    input.installTap(onBus: 0, bufferSize: 4_096, format: format) {
                        buffer, _ in
                        recordingSink.append(buffer)
                    }
                    audioEngine.prepare()
                    try audioEngine.start()
                    engine = audioEngine
                    sink = recordingSink
                    capturedURL = url
                    isRecording = true
                } catch {
                    errorMessage = AppModel.message("Recording failed.", error)
                }
            }
        }
    }

    private func stopRecording() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        sink = nil
        isRecording = false
    }

    private enum EnrollmentCaptureError: LocalizedError {
        case noInputFormat

        var errorDescription: String? {
            switch self {
            case .noInputFormat:
                String(localized: "No usable microphone input format was found.")
            }
        }
    }

    private func enroll() async {
        guard let url = capturedURL else { return }
        isExtracting = true
        errorMessage = nil
        defer { isExtracting = false }
        do {
            guard let runtime = model.runtime else { return }
            // Derselbe Extraktionspfad wie in der Diarisierung, damit
            // Enrolment- und Erkennungs-Einbettungen direkt vergleichbar
            // bleiben.
            let candidate = try await EnrollmentVoiceprintExtractor().extract(from: url)
            let store = try IdentityStore(layout: await runtime.library.layout)
            let snapshot = try await store.snapshot()
            var persons = snapshot.persons
            guard let index = persons.firstIndex(where: { $0.id == entry.id }) else {
                model.peopleError = "This person no longer exists."
                return
            }
            persons[index].prototypes.append(ManualEnrollment.prototype(
                personID: entry.id,
                from: candidate
            ))
            _ = try await store.replacePersons(
                persons,
                expectedRevision: snapshot.revision
            )
            try? FileManager.default.removeItem(at: url)
            capturedURL = nil
            dismiss()
            await finished()
        } catch VoiceEnrollmentError.sampleTooShort(let spoken) {
            errorMessage = String(
                localized: "Only \(Int(spoken.rounded())) seconds of detected speech - please record at least \(Int(VoiceEnrollmentSelector.minimumSpeechSeconds)) seconds."
            )
        } catch VoiceEnrollmentError.noSpeakerDetected {
            errorMessage = String(localized: "No voice was detected in this clip.")
        } catch {
            // Typisch fehlende Diarisierungsmodelle; der Provider nennt es.
            errorMessage = AppModel.message("The voiceprint could not be computed.", error)
        }
    }
}
