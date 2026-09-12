# iOS parity status

Status: 12 September 2026. This records the scoped iOS parity work, not a claim
that every macOS platform integration exists on iPhone or iPad.

## Implemented

| Area | iPhone and iPad behavior |
| --- | --- |
| Short recordings | An explicitly stopped recording shorter than 15 seconds keeps its original audio and a durable confirmation marker. Final transcription starts only after confirmation; live transcription during capture is unchanged. The deferred job retains the recording's language and processing generation. Interrupted capture continues through the existing recovery path. |
| Duration | Meeting duration uses the complete appended timeline, including offsets, rather than the longest individual asset. Home shows a duration when usable media metadata exists. |
| Home | Home is the initial route and offers recording, a new note, and the eight most recent meetings. Native list layout and adaptive metadata accommodate compact widths. Long titles wrap in the list and appear in full with the duration in meeting detail. Compact meeting toolbars place preparation and sharing in the actions menu. |
| Content search | Sidebar search defaults to notes, reports, and transcripts through the shared local search index. A scope control appears while searching. An indexing failure is visible and retains title search as a fallback. Removed meetings are filtered from results. |
| Library chat | Chat uses the shared source collector, prompt builder, streaming service, and endpoint-bound external-send consent. Scope can be all meetings, a folder, or selected meetings. Private conversation files persist across launches. Conflicting edits or deletion from another iPad window are rejected. |
| Meeting preparation | A meeting's preparation sheet explicitly selects related earlier reports using the shared title/confirmed-attendee matching and prompt logic. Empty sources and failures remain visible. External destinations require consent. |
| Recoverable deletion | Deletion cancels processing and flushes notes before moving the original meeting directory. iOS uses a private, backup-excluded library trash because system Trash is unavailable. Immediate Undo and Recently deleted support restoration, including after restart, without overwriting another meeting or reviving cancelled jobs or stale note editors. Deletion returns the affected window to Home; the dismissible Undo banner appears above the content without covering recording controls. |
| Lifecycle and localization | Navigation and chat state remain per window. Chat and preparation cancel when their view closes or the scene leaves the foreground. New UI and shared chat error messages include German and Traditional Chinese translations. |

The shared macOS chat extraction retains its existing partial-source read policy.
macOS continues using the system Trash. The iOS private trash does not automatically
purge originals; restored entries leave only small recovery metadata containers.
Unreadable trash entries remain on disk and are reported without hiding valid entries.

## Validation

Focused regression coverage includes deferred-job identity and idempotence, the
15-second boundary, content-index refresh and removal filtering, chat persistence
conflicts, cancelled/stale chat streams, restoration into occupied destinations,
fresh note-editor sessions after undo, and private trash discovery after restart.
Private-trash tests also cover empty interrupted containers and damaged receipts
alongside valid originals.

An independent code review identified and verified corrections for stale chat
deletion, stale preparation-task cleanup, preservation of the macOS source-read
policy, and interrupted trash preparation blocking other recoverable meetings.

The complete local suites passed on 12 September 2026:

| Suite | Tests | Suites | Result |
| --- | ---: | ---: | --- |
| Shared core | 1,488 | 176 | Passed with `swift test --package-path StenoKit --no-parallel`, matching the CI concurrency setting. |
| macOS app | 443 | 58 | Passed in a separate test build with an explicit disposable library and empty model directory. |
| iOS app | 504 | 49 | Passed after visual-QA fixes on an isolated iPhone 17 simulator running iOS 26.5. The saved `.xcresult` reports no failed or skipped tests. |
| iOS audio package | 35 | 5 | Passed on the iPhone 17 simulator. |

Counts refer to test declarations, including parameterized tests, rather than
counting every parameter value separately. The macOS storage-location form now
accepts an explicit environment in tests, so its saved-choice checks remain
independent of the test host's library override.

Actual simulator UI checks used only synthetic meeting notes and silent audio:

- iPhone: Home with long titles and durations; full-content search with note
  snippets and title-only no-results; deferred short-recording decisions;
  preparation with no related reports; chat scope selection, singular count,
  empty history, and an unsent draft above the software keyboard; compact
  meeting actions; Home, chat, and short-recording controls at enlarged text sizes.
- iPad: split navigation in portrait and landscape with enlarged text; full
  meeting titles and duration; short-recording decisions; delete and Undo;
  Recently deleted restoration after app restart, preserving the pending short
  recording decision; the top Undo banner and return to Home after deletion.

The default parallel core run encountered timeouts and a performance-budget
failure under load; the complete run using the repository's CI setting passed
without changing those assertions. The iOS localization check now validates
plural variants as well as flat values. A baseline layout-height test explicitly
sets its normal Dynamic Type size rather than inheriting simulator preferences.

## Remaining verification and platform limits

- Freeform iPad window resizing and simultaneous interaction across two scenes
  were not manually exercised. Per-window navigation and conflicting chat
  mutations are covered by regression tests.
- The final switch from a forced transcript-search drawer to automatic native
  placement builds and passes tests; its final visual recheck is pending because
  the host Mac relocked after the other simulator checks.
- Real microphone/background capture and actual model inference were not run in
  this maintenance task. Tests use isolated libraries, synthetic content, and fake
  model providers; no model download is required.
- Meeting preparation is meeting-based. Calendar-event ingestion is not part of
  this change. macOS system-audio capture, menu-bar controls, global shortcuts,
  and separate desktop windows remain platform-specific.
- The iOS private trash currently offers restoration, not permanent deletion or
  automatic expiry. Deleted originals continue occupying local storage.
- Simulator builds are not a physical-device or App Store release validation.
