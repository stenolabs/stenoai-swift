# Native AAC transfer audio

The Swift transfer exporter encodes mono/stereo PCM CAF export copies to AAC-LC
CAF using the dependency-free `StenoAudioEncoding` target and AudioToolbox.
Original files are never modified. Tracks remain separate, with their sample
rates, channel counts, valid frame counts and start-of-track timing preserved.

The preferred bitrate is 64,000 bit/s for mono and 128,000 bit/s for stereo.
At low sample rates (including 8 and 16 kHz), Apple's AAC encoder accepts lower
maximum bitrates. The encoder queries its applicable bitrate ranges and selects
the closest supported value, without resampling. These are encoder targets,
not a promise of exact output size. The returned `bitRate` reports the selection.

Observed with the local system codec: 8 kHz selects 24/48 kbit/s, 16 kHz
selects 48/96 kbit/s, and 48 kHz selects 64/128 kbit/s (mono/stereo).

Already-compressed CAF sources (including AAC and legacy Opus) pass through
byte-for-byte. PCM with more than two channels and files no larger than 32 KiB
also pass through. If AAC would increase size, the original CAF is exported.
No ffmpeg or model installation is involved.

## Library contract

`CAFEncoder.encode(source:destination:checkCancellation:)` borrows two open
regular-file descriptors. The destination must be empty and must not refer to
the same inode as the source. Input must be nonempty mono/stereo PCM CAF.
The caller creates the destination exclusively, retains ownership of both FDs,
and removes partial output on every error/cancellation. Neither descriptor is
closed by the encoder. Its result contains sample rate, channels, valid input
frame count and selected bitrate. Success means the output CAF, magic cookie,
and packet table were finalized; it does not publish a file.

The PCM working buffer is 8,192 frames, at most 64 KiB. AudioToolbox owns additional
codec buffers. Cancellation is checked before opening, between chunks and after
finalization. A failed run must not be treated as a usable output.

The Swift export adapter uses the existing private-root/session machinery and
exclusive destination FDs. It pins the source FD and checks the prepared inode,
size and SHA-256 before and after encoding. It checks disk headroom before each
track. The final output is independently inspected and bound to the archive
writer by identity and hash. The writer retains its existing atomic publication,
archive reread, path, symlink, resource-limit and hash checks.

## macOS helper contract, version 2

Build the standalone helper (Apple Silicon, deployment target macOS 14.4):

```sh
scripts/build-audio-helper.sh
.build/native-audio/helper-14.4/steno-audio-encode --version
scripts/test-audio-helper.sh
```

The standalone build compiles the same production sources directly with Swift 6,
without the app or model dependency graph. It does not lower either app's deployment
target. A verified `minos 14.4` load command establishes the deployment setting;
runtime acceptance on macOS 14.4 remains a separate check.

`TransferAudioConverter.convert` detects PCM CAF, RIFF/WAVE and WebM by header.
PCM CAF/WAV is encoded as AAC. Already-compressed CAF must be passed through by
the parent; the CLI deliberately does not handle that policy. Source identity,
size, modification/change timestamps and SHA-256 are checked across conversion.
The result includes the actual output hash and size. Hashes use bounded reads.

Invocation: `steno-audio-encode --input-fd 3 --output-fd 4`.
The parent must open the source read-only/no-follow, verify regular-file identity,
create an empty output exclusively in a private temporary directory, and pass
both descriptors through the child process's inherited stdio slots. Use an
argument array and `shell: false`; paths are not accepted by the helper.

On exit 0, stdout is one JSON object plus newline:

```json
{"codec":"aac","operation":"encoded-aac","sampleRate":48000,"channelCount":2,"frameCount":480013,"bitRate":128000,"sourceSHA256":"<64 lowercase hex digits>","outputSHA256":"<64 lowercase hex digits>","byteCount":160000}
```

For Opus the codec is `opus`, the operation is `repackaged-opus`, and `bitRate`
is omitted. Numeric values above are illustrative. Object key order is unspecified. On nonzero exit, stderr contains a diagnostic;
there is no success object. The parent must impose its normal timeout and output
limits, kill/wait for the child on cancellation, close descriptors, and remove
the task-owned partial output. SIGTERM/SIGKILL do not promise child-side cleanup.
The parent independently reopens/validates and hashes the completed output before
publishing it. Never pass original recordings as the output descriptor.

For Electron packaging, copy the ARM64 Release helper outside `app.asar` and sign
it as a nested executable with the application's Developer ID identity, hardened
runtime and timestamp **before** signing/notarizing the enclosing app. Verify
with `codesign --verify --strict` and inspect `codesign -d --verbose=4` and `otool -L`. This helper needs system audio-codec services, but no microphone, recording,
network or model permission. Distribution signing/notarization and the Electron
sandbox/child-launch configuration require integration testing; the local build
is not a distribution-signing acceptance test.

## Supported WebM subset

The FD-backed reader streams one 48 kHz Opus audio track with mapping family 0,
one or two channels, OpusHead version 1, zero gain, and input rate 0 or 48 kHz.
It accepts a timestamp scale of at most 1 ms and a unit track timestamp scale.
Tracks and timing metadata must precede audio. Content encodings and lacing are
not supported. These are helper compatibility limits, not claims that other
WebM files are invalid.

Every block timestamp is compared to the cumulative Opus packet duration within
one container timestamp tick. The first raw block timestamp must be zero. Gaps,
overlaps and start offsets outside that tolerance are rejected. CodecDelay must
match Opus pre-skip within one nanosecond; omission is accepted only for zero
pre-skip. Positive, integral-frame DiscardPadding is accepted only on the final
packet and cannot exceed that packet's duration. Negative/nonfinal padding and
unsupported block-group timing are rejected. Truncated declared payloads are
rejected; an unknown-length stream cannot prove that whole trailing packets were
not lost before it reached the helper.

Packets remain byte-identical. CAF packet-table priming/remainder represent the
pre-skip and final trim; `frameCount` is the audible frame count after both.
The finalized CAF is decoded in bounded chunks to verify native decodability and
exact valid duration. This validation does not re-encode the packets.

Input is capped at 16 GiB and four million EBML elements. Packet count is bounded
by those input limits rather than a separate duration-dependent packet cap.
The reader uses a 64 KiB window, caps an individual payload read at 1 MiB and
CodecPrivate at 64 KiB. Output batches target 128 packets or 64 KiB, with one
packet allowed to exceed that byte target. Native codec/packet-table allocations
are additional. Cancellation is checked throughout reading, writing and validation.
Every error requires parent cleanup of the partial output; there is no ffmpeg
fallback and no modification of source files.

## Reader and manifest integration

The transfer format remains version 1.0, `audio/track-N.caf` with media type
`audio/x-caf`. No new manifest fields are needed: its schema already identifies
the container, not PCM. Every audio JSON and manifest hash/byte count describes
the transported CAF, never the original PCM. Existing PCM readers must remain
supported. Swift derives codec and metadata through AudioToolbox after checking
the CAF header; it does not infer codec support from the extension.

Electron's current `inspectCAFHandle` is PCM-only. Before consuming this fixture,
it must support compressed CAF chunk parsing, including `desc`, `kuki`, `pakt`
and `data`. For AAC-LC `desc` has format ID `aac `, 1,024 frames per packet and
variable packet sizes. Parse packet count, valid frame count, priming and remainder
from `pakt`, bound variable-length packet-size decoding, and cross-check total
packet bytes against `data` (excluding the four-byte edit counter). Duration is
valid frames divided by sample rate, not encoded packets times 1,024. Priming
must not shift transcript or playback timing. Reject corrupt/missing/truncated
packet tables/cookies and inconsistent metadata. Continue all existing resource,
path, duplicate-entry, source-identity, SHA-256 and atomic-publication checks.
CAF Opus needs its own codec-specific validation; accepting AAC does not establish
Opus playback support. Decode with a native platform decoder, not a PCM cast.

In Electron, replace `prepareMeetingTransferAudio`'s Float32-PCM conversion with
an explicit policy: retain already suitable compressed CAF, invoke the helper
for mono/stereo PCM CAF or WAV, then inspect/hash the actual result and keep PCM
if it is smaller. Supported WebM Opus is repackaged without re-encoding. Do not
claim Windows compatibility from this macOS helper.

## Identity limitation

A lossy AAC export is not byte-identical to its native PCM source. Returning it
to that original library currently produces a safe conflict, not a no-op.
Identical package reimport into a receiving library still recognizes the stored
receipt. Re-export of imported AAC retains its bytes. AAC encoder output is not
assumed deterministic across runs or OS versions. Metadata similarity must never
be used to bypass the original-content hash comparison. Eliminating the native
self-reimport conflict needs a separately designed persisted export provenance
record bound to a verified library snapshot.

## Verification and fixture

`CAFEncoderTests` checks native encode/decode at 8/16/44.1/48 kHz, mono/stereo,
non-packet-aligned frame counts, per-channel signal correlation, size reduction,
immutable input, AAC pass-through, archive validation, cancellation, cleanup and
prepared-source replacement. `OpusCAFWriterTests` checks byte-identical Opus
transfer and native reader validation. `MeetingTransferEndToEndTests` covers
separate microphone/system tracks through export and library import, receipt
matching and the native-source conflict.

To retain the synthetic two-track AAC fixture during a test run, set
`STENO_AAC_FIXTURE_DIR` to a new task-owned directory and run:

```sh
swift test --package-path StenoKit --filter compressedMultitrackRoundTrip
```

The test writes `synthetic-aac.stenomeeting` and refuses to overwrite an existing
fixture. It contains generated tones and synthetic meeting text only. The local
handoff records the actual fixture and verification-log paths. Physical AirDrop,
Electron playback/import, production signing and physical iOS-device behavior
are separate acceptance checks.

The isolated `scripts/test-audio-helper.sh` runs the production helper sources
with synthetic WAV encode/decode, byte-identical real Opus packet remux, exact
pre-skip/end-trim and decoded sample comparison, timing/truncation rejection,
cancellation and source-mutation checks. It does not replace either app suite.
