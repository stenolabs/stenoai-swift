# UX and safety follow-up

Date: 2026-09-11. Working branch: `codex/legacy-look-preview`; starting commit: `97d0e70`.

This implements the actionable follow-ups from [the initial five-area Fable review](2026-09-11-ux-and-safety-review.md). That report describes the earlier baseline; the status below supersedes its open implementation items.

## Changes

- Ported the recording reliability series from local `main`, using the exact diff from `5299558^` through `c3df450`. This includes partial start, late track binding, missing-track disclosure, recording diagnostics, HAL microphone capture and device resolution per attempt. Resolved the integration against this branch's existing UI, native-Gemma and transcription-language behavior. This is a local source port, not a merge or a change to `main`.
- Bound speaker review and Markdown export to the displayed transcript's exact diarization run. Preserved outgoing review documents under `review-history/<runID>.json` before replacing `review.json`. Added a corrected-old-revision/newer-run fixture. Ambiguous provenance yields no review.
- Bound pending-transcript adoption to both displayed revision IDs. A stale click refreshes the candidate instead of accepting a replacement that appeared in the meantime. A no-op speaker-recognition request now explains why no new work was scheduled.
- Deferred transcription after a failed recording stop until capture adoption succeeds on macOS and iOS. Unreadable originals remain in place. Recovery schedules fresh processing for newly adopted audio even if an older job finished. A durable recovery marker covers interruption after the last CAF was adopted but before the follow-up job was persisted.
- Represented each continuity gap as one writer-queue event. Silence is materialized in bounded chunks by the writer. A synthetic 120-second gap preserves resumed audio with a two-slot queue. Rejected final silence reports overflow rather than silently shortening the timeline.
- Bound external-send acknowledgement to the full endpoint configuration, including changes while the sheet is open and during asynchronous library-source collection. A changed endpoint needs fresh acknowledgement. Corrected the Anthropic live-query header to `x-api-key`; verification used an intercepted synthetic transport, not a remote request.
- Re-read active jobs after cancellation before moving a meeting to Trash. This catches a child enqueued after the initial snapshot when the parent completes just before cancellation. Unchanged active jobs fail safely instead of looping forever. A deterministic test covers the parent-to-child interleaving.
- Added visible **New note** on Home; made draft recording explicit and removed its competing global recording toolbar action. Home emphasizes dates for older entries and omits empty chronology labels. Full speaker-origin wording appears once per visible speaker, with accessible tooltip icons on later rows. Added German and Traditional Chinese translations for the imported notices and new strings.

## Verification

| Suite | Result |
| --- | --- |
| StenoKit, `swift test --no-parallel` | 1,480 tests, 175 suites passed |
| macOS application | 436 tests, 56 suites passed |
| iOS application, iPhone 17 simulator | 487 tests, 45 suites passed |
| StenoiOSKit, iPhone 17 simulator | 35 tests, 5 suites passed |

The initial parallel Swift run timed out in 12 short-deadline pipeline tests under concurrent build load. The complete serial rerun passed. Compilation and catalog failures found during integration were corrected before the final passing runs. `git diff --check` passed.

Visual checks used a separately identified, disposable macOS app with its own library and empty model directory. Home, draft creation without recording, the unique draft recording action, older Home dates, and synthetic meeting detail were inspected. No recording permission was requested and no model was installed or executed. Screenshots and test/reviewer logs are retained under `.build/current-run/ux-followup-evidence/` (ignored).

## Independent review and remaining limits

All three attempted Fable follow-up reviews (audio, provenance, privacy/UX) returned a session-limit response, not a review. The earlier five-area Fable review remains available, but **these new changes have not received Fable's independent follow-up approval**. Do not describe the attempts as completed reviews. Retry after the service limit resets; review the final diff and screenshots, not the initial snapshot.

No physical microphone, lid/wake, disk-full or live external-provider acceptance test was performed. Synthetic continuity, recovery, transport and revision fixtures establish the tested behavior, not hardware acceptance.

The small, previously accepted native-undo retention limitation remains: an undo handle may remain in the model if the window's UndoManager discards its action independently. There is no duplicate restoration through a consumed handle. Optional Keychain policy changes and speculative inactive MCP exposure were not adopted as defects.

No push, hosted-platform write, production replacement or merge into `main` was performed. The user's existing running Steno instance was left untouched. The required independent follow-up review remains a gate before consequential integration.
