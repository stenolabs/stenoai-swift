# Short recording confirmation on macOS

Requested recording stops below 15 seconds retain their audio and defer final
transcription until the user confirms. Exactly 15 seconds follows the normal
automatic path. The duration comes from the newly captured assets, including
when extending an existing meeting.

The meeting detail shows Transcribe and Move to Trash for a new meeting, or
Transcribe and Later for an extension. Existing transcript revisions remain
untouched. The deferred job retains its original processing pins in a meeting
sidecar, survives restart, and travels with the meeting through Trash/restore.
Another explicit transcription request consumes the pending confirmation.

Imports, error recovery, live recognition during recording, and iOS behavior
are unchanged. Unknown duration follows the existing automatic path.

## Validation

- macOS: 440 tests in 57 suites passed.
- Focused tests cover the duration boundary, deferred-job persistence, normal
  scheduling, stale-decision removal protection, and transcription requested
  through another entry point.
- An isolated app with synthetic metadata showed both button combinations.
  Restart preserved the prompt; Later dismissed it. Opening the prompt created
  no processing job. This was visual verification, not a hardware recording or
  speech-model execution test.
- Fable reviewed the stop path and persistence behavior. Follow-up changes
  consume stale prompts after another transcription request, suppress repeated
  read-error notices, report generation conflicts, and avoid treating unknown
  duration as zero. Fable's targeted follow-up found no concrete remaining
  defects in these corrections.

Local review output, screenshots, and test logs are retained under
`.build/current-run/short-recording-review/`.
