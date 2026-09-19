# StenoAI for iPhone and iPad

The iOS application is displayed as **StenoAI**. The Xcode scheme, Swift module,
and build product remain `Steno`. The minimum versions are iOS 26 and iPadOS 26.

## Local signing

`Config/Signing.xcconfig` inherits the repository's shared signing defaults.
To use a different team or app identifier on iOS, create the ignored
`iOS/.steno-signing.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
STENO_BUNDLE_IDENTIFIER = your.registered.app.identifier
```

Use an explicit App ID registered in that team, with a matching App Store
Connect app record. The display name does not change the bundle identifier.
Creating this file does not register an App ID or grant distribution access.

## Prepare an internal TestFlight build

Run these commands from `iOS/`. Keep one task-specific build directory, and use
an isolated simulator for tests. A simulator's name can resolve to the wrong
runtime when multiple iOS versions are installed; prefer its exact identifier.

```sh
xcodegen generate
xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath build/TestFlight test

xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/TestFlight \
  -archivePath build/TestFlight/StenoAI.xcarchive archive
```

Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` before
archiving. Check App Store Connect for an unused build number. The export
configuration preserves those numbers.

Inspect the archive's identity, supported devices, privacy manifest, localized
permission text, signing, and provisioning profile. An archive made with
`CODE_SIGNING_ALLOWED=NO` proves compilation and packaging only; it is not a
distributable build.

With the team's distribution credentials and profiles available, the following
configuration exports locally and restricts the build to internal TestFlight:

```sh
xcodebuild -exportArchive \
  -archivePath build/TestFlight/StenoAI.xcarchive \
  -exportOptionsPlist Config/ExportOptions-TestFlight.plist \
  -exportPath build/TestFlight/Export
```

Upload is a separate, explicitly authorized action. In Xcode Organizer, use
**TestFlight Internal Only**. After Apple processes the build, resolve any
export-compliance questions, add it to the approved internal group, and verify
installation from TestFlight. Internal testers need access through App Store
Connect; Developer Program membership alone does not prove tester access.

See Apple's [internal tester instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
and [required reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

## Device acceptance and current limits

Use synthetic content for acceptance. Check recording without a model, denied
microphone access, screen locking, interruptions, reopening after a process
termination, playback of the saved original, and deferred processing after a
return to the foreground. Approve a specific model installation before testing
real inference; select the spoken language explicitly. Check both iPhone and
iPad, including iPad window changes.

The iOS library is unencrypted, visible in Files, and excluded from device
backup. Meeting exports are unencrypted and are not complete library backups.
Long post-processing may pause in the background. Reports, preparation, and chat
can send selected content to an explicitly configured model server after the
app's consent flow. The privacy manifest does not replace the App Store Connect
privacy and encryption declarations or an acceptance test on a real device.
