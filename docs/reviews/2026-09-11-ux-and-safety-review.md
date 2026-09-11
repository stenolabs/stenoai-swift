# macOS UX changes and focused Fable reviews

Date: 2026-09-11. Baseline: `cb03519` on `codex/legacy-look-preview`, plus the local UX changes delivered with this report.

Implementation follow-up: [current fixes, verification and remaining review gate](2026-09-11-safety-followup.md). The findings below describe the original review baseline.

## Delivered changes

- Home and the main toolbar say **Start Recording** and use a recording symbol. **New note** in the File menu, command palette and draft toolbar action creates a draft; Cmd-N remains a draft action.
- Localized sidebar recording/processing/review status, meeting status, audio level labels, voice-sample counts and match labels. Added German and Traditional Chinese catalog entries, including search controls, date groups, the draft instruction and trash toast. This is not a complete translation audit of every existing feature.
- Native Edit > Undo restores a deleted batch after the 12-second toast expires. Separate deletions retain separate undo steps. Each handle is consumed once; failed restores retain only retryable items, without overwriting occupied destinations. The toast announces the native undo action to accessibility clients.
- Removed the duplicate timer and audio meters from the recording detail header. The persistent recording strip owns those indicators, including the paused-microphone state. Pause/resume and device/language warnings remain in the detail header.
- Separated the folder heading from its add button, added a heading accessibility trait, mentioned Trash in the multi-selection help, and stopped highlighting Home when the recording-specific empty state is displayed.

## Review method and limits

Claude Fable reviewed recording/recovery, trash/restore, result provenance and privacy as four separate source reviews. A fifth review used seven current screenshots: empty home, general settings, empty people settings, populated home, meeting detail, draft and trash toast. A targeted follow-up reviewed the native undo corrections.

Source reviews used scoped source copies, without user settings or meeting data. The undo follow-up inspected the same named source/test files in the working tree. Screenshots came from a separately identified app with a disposable library, a separate empty model directory and bundled synthetic demo meetings. No model was downloaded or run, no external inference request was made, and no live microphone/system recording was used for visual QA. Recording layout therefore has source/build coverage, not visual acceptance during capture. Screen-reader announcements were implemented and compiled but not audited with a running screen reader.

Fable's findings were checked against current source by the implementing agent. The reviewer did not run tests. No broad backend changes were made in response to this review.

Raw reviewer responses and synthetic screenshots are retained locally under `.build/current-run/ux-review-evidence/` and are not tracked. The screenshots precede the last supplemental localization changes and multiple-undo refinement.

## Important branch divergence

Local `main` is `c3df450`. It contains `83a7ee1` (partial recording start), `f47241a` (late track binding), `30a6508` (missing-track disclosure), `78955ad` (notice localization), and later microphone fixes that are **not ancestors of this UI branch**. Conversely, this branch has UI/native-Gemma work that is not on local `main`. This was verified locally with branch containment and history, not against a live remote.

Do not interpret the old recording handoff as evidence that those fixes are present here. Reconcile the two lines of work before proposing another implementation of their already-addressed behavior. No merge, push or publication was performed.

## Prioritized open findings

### P1: Speaker review can target a different run than the displayed corrected transcript

**Source-confirmed; end-to-end reproduction still needed.** `MeetingDetailView.refreshLoop` loads the current revision and separately calls `AppModel.loadReviewData` without a diarization run. `MeetingReviewAssembler.load` then selects the latest suggestion run. When a user edit remains current and a retranscription is parked, the displayed transcript and review panel can therefore follow different runs. `MeetingReviewStore` stores one `review.json`; confirming the newer run can overwrite the review for the older, still-displayed revision. The speaker presenter correctly rejects mismatched run identities, so the symptom is lost visible confirmations, not a verified wrong-name assignment.

Next: reproduce corrected revision A plus parked run B with synthetic fixtures; bind the panel to the displayed revision and decide how per-run review history is retained. Relevant files: `App/Sources/MeetingDetailView.swift`, `App/Sources/AppModel+Review.swift`, `StenoKit/Sources/StenoPipeline/MeetingReview.swift`.

### P1: Partial capture finalization can schedule transcription before all tracks are adopted

**Source-confirmed path; disk-error injection still needed.** `RecordingSession.finalizeStop` registers tracks sequentially. If registration of a later track fails, an earlier asset may already be registered while the remaining CAF is stranded. `RecordingStopFollowUp.make(stopFailed:)` still requests final ASR. `CaptureRecovery` later adopts the remaining track but treats a finished final-ASR job for the generation as sufficient, so the adopted track may not be transcribed. The same follow-up policy is also present on local `main`.

Next: inject failure during registration of the second track and verify recovery/job ordering. Preserve all original capture files. Relevant files: `StenoKit/Sources/StenoAudioCore/RecordingSession.swift`, `CaptureRecovery.swift`, `App/Sources/AppModel.swift`.

### P2: External-model acknowledgement is not bound to its destination

**Source-confirmed.** `AskBarView` and `LibraryChatWindow` each keep a Boolean acknowledgement. Changing the selected endpoint does not reset it, although the notice names a specific host. A later question can therefore go to the newly selected, configured host without a fresh destination notice. No transmission to an unconfigured host was demonstrated.

Next: bind acknowledgement and confirmation to the actual endpoint configuration, including changes while a confirmation is open, and test A-to-B switching. Relevant files: `App/Sources/AskBarView.swift`, `LibraryChatWindow.swift`, `ExternalModelNotice.swift`.

### P2: Adopting a pending transcript does not bind the user's displayed candidate

**Source-confirmed.** macOS `AppModel.adoptPendingTranscript` supplies only the meeting ID. `RevisionStore.adoptPendingRevision` already supports expected current and candidate IDs, and the iOS caller uses them. A newer candidate arriving before the click can be adopted instead of the one shown.

Next: pass both displayed revision IDs and reload on a stale action. Relevant files: `App/Sources/AppModel+Transcript.swift`, `StenoKit/Sources/StenoLibrary/RevisionStore.swift`.

### P2: Long continuity gaps can outrun the writer ring

**Hypothesis with source evidence, not a reproduced hardware failure.** `TrackContinuity.fillSilence` stops filling when the bounded writer ring rejects a silence buffer; `receive` nevertheless clears host realignment and attempts to write real audio. After a sufficiently long gap this can lose alignment or trigger overflow handling. The reviewer used lid-close/wake as a candidate trigger. The exact capacity/duration under scheduling and actual hardware was not measured.

Next: deterministic synthetic gap larger than the ring capacity, then bounded device testing if warranted. Relevant file: `StenoKit/Sources/StenoAudioCore/TrackContinuity.swift`.

### Other scoped findings

- **Source-confirmed on this branch:** failed recording preparation can leave a zero-frame capture that recovery adopts. Compare the missing partial-start fixes on local `main` before fixing this independently.
- **Source-confirmed:** the live-query Anthropic path builds `/messages` but applies a Bearer authorization header, unlike the dedicated Anthropic provider's `x-api-key`. Actual remote response was not tested. Correct with a transport fixture, not a real request.
- **Source-confirmed silent path:** requesting diarization after a corrected old revision and a completed newer run can return without enqueueing or explaining why. Resolve alongside the run-binding work.
- **Unconfirmed concurrency concern:** a downstream job may arrive between the trash job snapshot and removal. Requires a deterministic coordinator/deletion interleaving test before selecting a fix.
- **Low-priority accepted limitation of this change:** unused native undo handles remain in the model if the window's UndoManager independently discards its action. Multi-window ownership would need a separate policy if multiple main windows are introduced. No duplicate restoration is possible through a consumed handle.
- **Not adopted as a defect:** device-only Keychain storage was suggested as an optional policy difference. No unintended disclosure was demonstrated. MCP controller/settings currently have no call sites in the reviewed build; hypothetical future wiring is not an active exposure.
- **Rejected as unsupported:** the provenance reviewer questioned whether final-ASR/diarization set the committing phase after not reading those sections. The coordinator contains explicit `.committing` assignments in those paths.

## Visual review conclusions

Keep the current home hierarchy, detail ordering, empty states, persistent recording strip and unobtrusive undo placement. Fable found no need for a redesign.

Useful follow-ups, not implemented here:

1. Make **New note** visible on Home or enable its dedicated toolbar action by default; the current default hides it in the options menu.
2. Distinguish **start a new recording** from **record into this draft**. Drafts currently expose both actions with similar icons. The English draft instruction was corrected after the screenshots.
3. Reduce repeated imported-speaker provenance text while preserving the distinction between imported labels and confirmed identities.
4. Make the date more prominent than the time in older Home entries; avoid the empty-state combination of “Previous” and “Now”.

The review's suggestion that transcription language should follow the system language was not adopted: spoken language must be explicitly selected, and the screenshot came from a skipped isolated onboarding flow.

## Verification

Final macOS verification: **415 tests in 50 suites passed**, `xcodebuild test` succeeded using `.build/current-run`. The baseline had 410 tests; the five added tests cover native undo after toast expiry, multiple independent undo steps, consumed handles, occupied-destination retry and missing trash URLs. `git diff --check` passed. All implementation changes are confined to the macOS app, its catalog/tests, and this report; no StenoKit or iOS source was modified. Consequently the macOS suite was run, not the four-suite shared-package matrix.

UI checks with synthetic data confirmed: isolated storage path, translated ready status, Cmd-N creates a draft without recording, and native Edit > Undo restores a trashed draft after the toast has expired. All destructive UI operations affected only the disposable synthetic draft. Real meetings were not used for these checks.
