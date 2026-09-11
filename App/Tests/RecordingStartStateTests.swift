import Foundation
import StenoAudioCore
import StenoDomain
import StenoMacAudio
import StenoTranscription
import Testing
@testable import steno_macos

@Suite("Recording start state")
struct RecordingStartStateTests {
    @Test("system audio permission cache is reused only for the same executable identity")
    func reusesPermissionCacheForSameIdentity() {
        let status = RecordingPermissionCache.reusableStatus(
            rawStatus: AudioPermissionStatus.authorized.rawValue,
            cachedIdentity: "team:ABC|identifier:org.steno.Steno",
            currentIdentity: "team:ABC|identifier:org.steno.Steno"
        )

        #expect(status == .authorized)
    }

    @Test("a changed or missing executable identity forces a fresh permission probe")
    func invalidatesPermissionCacheForAnotherIdentity() {
        #expect(RecordingPermissionCache.reusableStatus(
            rawStatus: AudioPermissionStatus.denied.rawValue,
            cachedIdentity: "adhoc:old",
            currentIdentity: "adhoc:new"
        ) == nil)
        #expect(RecordingPermissionCache.reusableStatus(
            rawStatus: AudioPermissionStatus.authorized.rawValue,
            cachedIdentity: nil,
            currentIdentity: "team:ABC|identifier:org.steno.Steno"
        ) == nil)
    }

    @Test("an inconclusive system audio status always triggers a fresh probe")
    func invalidatesInconclusivePermissionStatus() {
        #expect(RecordingPermissionCache.reusableStatus(
            rawStatus: AudioPermissionStatus.notDetermined.rawValue,
            cachedIdentity: "team:ABC|identifier:org.steno.Steno",
            currentIdentity: "team:ABC|identifier:org.steno.Steno"
        ) == nil)
    }

    @Test("signing identity stays stable for a team and uses cdhash for ad hoc builds")
    func derivesSigningIdentityCacheKey() {
        #expect(CodeSigningIdentity(
            teamIdentifier: "ABC",
            signingIdentifier: "org.steno.Steno",
            cdHash: "ignored"
        ).cacheKey == "team:ABC|identifier:org.steno.Steno")
        #expect(CodeSigningIdentity(
            teamIdentifier: nil,
            signingIdentifier: "org.steno.Steno",
            cdHash: "1234"
        ).cacheKey == "adhoc:org.steno.Steno|cdhash:1234")
    }

    @Test("the development app has a stable team-signed identity")
    func developmentAppUsesStableSigningIdentity() throws {
        let identity = try #require(CurrentCodeSigningIdentity.cacheKey())

        // Machines without the ignored local `.steno-signing.xcconfig` build
        // ad hoc; TCC then re-prompts on every build.
        // The stable-team contract can only hold where a DEVELOPMENT_TEAM is
        // actually configured, so ad-hoc machines skip the assertion.
        guard !identity.hasPrefix("adhoc:") else { return }

        #expect(identity.hasPrefix("team:"))
        #expect(identity.hasSuffix("|identifier:org.steno.Steno"))
    }

    @Test("a targeted meeting snapshot replaces only the matching sidebar row")
    func replacesAffectedMeetingSnapshot() {
        let firstID = MeetingID()
        let secondID = MeetingID()
        let first = Meeting(id: firstID, title: "First", status: .processing)
        let second = Meeting(id: secondID, title: "Second", status: .ready)
        let updated = Meeting(id: firstID, title: "First", status: .ready)

        let result = MeetingListSnapshot.replacing(
            updated,
            in: [first, second]
        )

        #expect(result == [updated, second])
    }

    @Test("automatic mode selects the microphone used by the meeting app")
    func detectsTheMicrophoneUsedByTheMeetingApp() throws {
        let airPods = MicrophoneDevice(uid: "airpods", name: "AirPods")
        let selected = try RecordingMicrophoneSelection.resolve(
            mode: .automatic,
            discovery: MicrophoneDiscoverySnapshot(
                availableDevices: [airPods],
                activeDevices: [airPods],
                activeClients: [
                    ActiveMicrophoneClient(
                        processID: 100,
                        bundleIdentifier: "com.hnc.Discord",
                        deviceUIDs: ["airpods"]
                    ),
                ],
                hasUnresolvedActiveDevices: false
            )
        )

        #expect(selected == airPods)
    }

    @Test("manual mode never falls back to another available microphone")
    func rejectsMissingManualMicrophone() {
        let airPods = MicrophoneDevice(uid: "airpods", name: "AirPods")
        let camera = MicrophoneDevice(uid: "camera", name: "Studio Display")

        #expect(throws: AudioRecordingError.self) {
            try RecordingMicrophoneSelection.resolve(
                mode: .manual(airPods),
                discovery: MicrophoneDiscoverySnapshot(
                    availableDevices: [camera],
                    activeDevices: [camera],
                    activeClients: [],
                    hasUnresolvedActiveDevices: false
                )
            )
        }
    }

    @Test("automatic mode requires one unambiguous microphone")
    func rejectsAmbiguousAutomaticMicrophones() {
        let airPods = MicrophoneDevice(uid: "airpods", name: "AirPods")
        let camera = MicrophoneDevice(uid: "camera", name: "Studio Display")

        #expect(throws: AudioRecordingError.self) {
            try RecordingMicrophoneSelection.resolve(
                mode: .automatic,
                discovery: MicrophoneDiscoverySnapshot(
                    availableDevices: [airPods, camera],
                    activeDevices: [airPods, camera],
                    activeClients: [],
                    hasUnresolvedActiveDevices: false
                )
            )
        }
    }

    @Test("manual selection wins over an automatically detected device")
    func respectsManualMicrophoneSelection() throws {
        let airPods = MicrophoneDevice(uid: "airpods", name: "AirPods")
        let camera = MicrophoneDevice(uid: "camera", name: "Studio Display")

        let selected = try RecordingMicrophoneSelection.resolve(
            mode: .manual(camera),
            discovery: MicrophoneDiscoverySnapshot(
                availableDevices: [airPods, camera],
                activeDevices: [airPods],
                activeClients: [],
                hasUnresolvedActiveDevices: false
            )
        )

        #expect(selected == camera)
    }

    @Test("microphone selection survives an app restart")
    func persistsMicrophoneSelection() throws {
        let suiteName = "RecordingStartStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MicrophoneSelectionStore(defaults: defaults)
        let mode = RecordingMicrophoneMode.manual(
            MicrophoneDevice(uid: "airpods", name: "AirPods")
        )

        #expect(store.load() == .automatic)
        store.save(mode)
        #expect(store.load() == mode)
    }

    @Test("a second start is rejected while permission and audio setup are pending")
    func rejectsConcurrentStart() {
        var state = RecordingStartState()

        let firstStart = state.begin()
        #expect(firstStart)
        #expect(state.isStarting)
        let secondStart = state.begin()
        #expect(!secondStart)
    }

    @Test("a failed start releases the gate and identifies its unfinished meeting")
    func releasesAfterFailure() {
        var state = RecordingStartState()
        let meetingID = MeetingID()

        let firstStart = state.begin()
        #expect(firstStart)
        state.didCreateMeeting(meetingID)

        let failedMeetingID = state.fail()
        #expect(failedMeetingID == meetingID)
        #expect(!state.isStarting)
        let retry = state.begin()
        #expect(retry)
    }

    @Test("a meeting created during startup is exposed as active until startup finishes")
    func exposesCreatedMeetingAsActive() {
        var state = RecordingStartState()
        let meetingID = MeetingID()

        // Mutierende Methoden gehoeren vor das Makro. #expect packt seinen
        // Ausdruck in eine Closure mit unveraenderlichem Empfaenger, ein
        // direkter Aufruf uebersetzt dort nicht.
        let started = state.begin()
        #expect(started)
        state.didCreateMeeting(meetingID)
        #expect(state.activeMeetingID == meetingID)

        state.succeed()
        #expect(state.activeMeetingID == nil)
    }

    @Test("the language picker explains recording and startup locks")
    func explainsLanguagePickerLocks() {
        let recordingLock = String(localized: "The transcription language cannot change while a recording is running.")
        let startingLock = String(localized: "The transcription language cannot change while a recording is starting.")
        let preparingLock = String(localized: "The transcription language cannot change while transcription is being prepared.")
        #expect(
            TranscriptionLanguagePickerPresentation.lockMessage(
                isRecording: true,
                isStartingRecording: false,
                isPreparingPipeline: false
            ) == recordingLock
        )
        #expect(
            TranscriptionLanguagePickerPresentation.lockMessage(
                isRecording: false,
                isStartingRecording: true,
                isPreparingPipeline: false
            ) == startingLock
        )
        #expect(
            TranscriptionLanguagePickerPresentation.lockMessage(
                isRecording: false,
                isStartingRecording: false,
                isPreparingPipeline: true
            ) == preparingLock
        )
        #expect(
            TranscriptionLanguagePickerPresentation.lockMessage(
                isRecording: false,
                isStartingRecording: false,
                isPreparingPipeline: false
            ) == nil
        )
    }

    @Test("a completed start releases the pending gate without failing its meeting")
    func releasesAfterSuccess() {
        var state = RecordingStartState()
        let meetingID = MeetingID()

        let firstStart = state.begin()
        #expect(firstStart)
        state.didCreateMeeting(meetingID)
        state.succeed()

        #expect(!state.isStarting)
        let failedMeetingID = state.fail()
        #expect(failedMeetingID == nil)
    }

    @Test("stopping consumes exactly one recording's live transcript tasks")
    func consumesOneLiveTaskBatchPerRecording() async {
        let firstOutput = TranscriptOutput(
            localeIdentifier: "de-DE",
            blocks: []
        )
        let secondOutput = TranscriptOutput(
            localeIdentifier: "en-US",
            blocks: []
        )
        var tasks = RecordingLiveTaskSet()
        tasks.append(Task<TranscriptOutput?, Never> { firstOutput })

        let firstBatch = tasks.takeForStop()
        tasks.append(Task<TranscriptOutput?, Never> { secondOutput })
        let secondBatch = tasks.takeForStop()
        let firstResult = await firstBatch[0].value
        let secondResult = await secondBatch[0].value

        #expect(firstBatch.count == 1)
        #expect(firstResult == firstOutput)
        #expect(secondBatch.count == 1)
        #expect(secondResult == secondOutput)
        #expect(tasks.isEmpty)
    }

    @Test("starting a new recording cancels every stale live transcript task")
    func cancelsStaleLiveTasksBeforeRecording() {
        let task = Task<TranscriptOutput?, Never> {
            try? await Task.sleep(for: .seconds(60))
            return nil
        }
        var tasks = RecordingLiveTaskSet()
        tasks.append(task)

        tasks.cancelAndDiscard()

        #expect(task.isCancelled)
        #expect(tasks.isEmpty)
    }

    @Test("a failed stop defers transcription until capture recovery succeeds")
    func failedStopDefersFinalTranscription() {
        let followUp = RecordingStopFollowUp.make(stopFailed: true)

        #expect(followUp.meetingStatusCorrection == .interrupted)
        #expect(followUp.jobKinds.isEmpty)
    }
}
