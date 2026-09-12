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

## macOS helper contract, version 1

Build only the helper (Apple Silicon, deployment target macOS 26):

```sh
swift build --package-path StenoKit -c release --product steno-audio-encode
StenoKit/.build/release/steno-audio-encode --version
```

Invocation: `steno-audio-encode --input-fd 3 --output-fd 4`.
The parent must open the source read-only/no-follow, verify regular-file identity,
create an empty output exclusively in a private temporary directory, and pass
both descriptors through the child process's inherited stdio slots. Use an
argument array and `shell: false`; paths are not accepted by the helper.

On exit 0, stdout is one JSON object plus newline:

```json
{"sampleRate":48000,"channelCount":2,"frameCount":480013,"bitRate":128000}
```

Object key order is unspecified. On nonzero exit, stderr contains a diagnostic;
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
for mono/stereo PCM CAF, then inspect/hash the actual result and keep PCM if it
is smaller. This helper does not accept WebM; use the separately reviewed legacy
Opus repackaging path where applicable. Do not claim Windows compatibility from
this macOS helper.

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
