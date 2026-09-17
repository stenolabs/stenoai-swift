import Foundation
import StenoDomain
import SwiftUI

@MainActor
extension AppModel {
    func pendingShortRecording(_ id: MeetingID) async throws -> ShortRecordingDecision? {
        guard let snapshot = runtimeSnapshot(), isCurrent(snapshot) else { return nil }
        let result = try await ShortRecordingDecisionStore(layout: snapshot.runtime.library.layout)
            .pending(id, jobStore: snapshot.runtime.jobStore)
        guard isCurrent(snapshot) else { return nil }
        return result
    }

    func confirmShortRecording(_ decision: ShortRecordingDecision) async throws {
        guard !recording.isActive, let operation = beginLibraryOperation() else {
            throw AppModelLibraryOperationError.operationInProgress
        }
        defer { endFolderOperation(operation) }
        guard let snapshot = runtimeSnapshot() else { return }
        let store = ShortRecordingDecisionStore(layout: snapshot.runtime.library.layout)
        guard try await store.pending(decision.job.meetingID, jobStore: snapshot.runtime.jobStore)?.job.id == decision.job.id else { return }
        let meeting = try await snapshot.runtime.library.loadMeeting(decision.job.meetingID)
        guard isCurrent(snapshot, operation: operation), !recording.isActive,
              meeting.status != .recording,
              meeting.processingGenerationID == decision.job.processingGenerationID else {
            throw AppModelLibraryOperationError.operationInProgress
        }
        _ = try await snapshot.runtime.jobStore.ensureEnqueued(decision.job)
        try store.remove(meeting.id, expectedJobID: decision.job.id)
    }
}

struct ShortRecordingBanner: View {
    @Environment(AppModel.self) private var app
    let meetingID: MeetingID
    @State private var decision: ShortRecordingDecision?
    @State private var dismissed: JobID?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let decision, decision.job.id != dismissed, !app.recording.isActive {
                VStack(alignment: .leading, spacing: 8) {
                    Text("That was a short recording.").font(.headline)
                    Text("Your audio is saved. Would you like to transcribe it anyway?")
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(decision) }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 12) { actions(decision) }
                    }
                    .disabled(isWorking || app.libraryActionIsInFlight)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
        }
        .task(id: meetingID) {
            while !Task.isCancelled {
                do { decision = try await app.pendingShortRecording(meetingID) }
                catch { errorMessage = error.localizedDescription; return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .alert("Recording", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func actions(_ decision: ShortRecordingDecision) -> some View {
        Button("Transcribe") {
            perform { try await app.confirmShortRecording(decision) }
        }
        .frame(minHeight: 44)
        Button("Later") { dismissed = decision.job.id }.frame(minHeight: 44)
        Button("Move to Trash", role: .destructive) {
            perform { _ = try await app.deleteMeeting(meetingID) }
        }
        .frame(minHeight: 44)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await action()
                decision = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
