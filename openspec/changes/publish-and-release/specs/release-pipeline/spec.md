## ADDED Requirements

### Requirement: Tag-driven release build
The CI system SHALL build and publish a release **only** in response to a pushed git tag matching `v<MAJOR>.<MINOR>.<PATCH>` (optionally with a pre-release suffix, e.g. `v0.1.0-rc1`), running on a macOS runner whose toolchain satisfies the package's `swift-tools-version`. Pushes to branches SHALL NOT trigger a release.

#### Scenario: Version tag triggers a release
- **WHEN** a tag `v0.1.0` is pushed to the repository
- **THEN** CI builds the app on a macOS runner and publishes a GitHub Release named for that tag with the packaged DMG attached

#### Scenario: Branch push does not release
- **WHEN** a commit is pushed to a branch without a matching version tag
- **THEN** no GitHub Release is created and no DMG is published

#### Scenario: Toolchain mismatch fails fast
- **WHEN** the runner's Swift toolchain is older than the package's required `swift-tools-version`
- **THEN** the workflow fails early with a clear toolchain-version message rather than partway through the build

### Requirement: Developer ID signing with hardened runtime
The released app SHALL be signed with a **Developer ID Application** identity and built with the hardened runtime enabled, using the existing entitlements. The signing identity SHALL be imported into an ephemeral keychain that is removed after the job, and signing credentials SHALL come from CI secrets that are never written to logs.

#### Scenario: Released app is Developer-ID signed
- **WHEN** the published DMG's contained app is inspected with `codesign`
- **THEN** it shows a valid Developer ID Application signature with the hardened runtime flag set

#### Scenario: Credentials are not leaked or left behind
- **WHEN** the workflow finishes (whether it succeeds or fails)
- **THEN** the temporary signing keychain is deleted and no secret value appears in the job logs

### Requirement: Notarization and stapling
The released DMG SHALL be submitted to Apple notarization via `notarytool` and, on acceptance, SHALL have the notarization ticket **stapled** so the ticket is present offline. Gatekeeper SHALL accept the stapled DMG without the user removing the quarantine attribute.

#### Scenario: DMG is notarized and stapled
- **WHEN** the release DMG is produced
- **THEN** notarization returns "Accepted" and the ticket is stapled to the DMG

#### Scenario: Gatekeeper accepts the download
- **WHEN** a user downloads the released DMG and opens the contained app
- **THEN** Gatekeeper allows it after at most the standard one-time "downloaded from the internet" confirmation, with no "unidentified developer" block and no manual `xattr` step required

### Requirement: DMG release artifact
The release asset SHALL be a compressed DMG containing `ThreeFingerSwitcher.app` and a symbolic link to `/Applications`, so the user can drag-install. The DMG SHALL be produced by a repeatable script (no manual Disk Utility steps).

#### Scenario: DMG contains app and Applications link
- **WHEN** the release DMG is mounted
- **THEN** it shows `ThreeFingerSwitcher.app` alongside a link to `/Applications`

#### Scenario: DMG is the published asset
- **WHEN** the GitHub Release is created for the tag
- **THEN** the DMG is attached as a downloadable release asset

### Requirement: Release version derived from the tag
The bundle's `CFBundleShortVersionString` in the released app SHALL equal the tag's version (the tag with the leading `v` removed), and `CFBundleVersion` SHALL be a build number that does not decrease between releases. The repository's checked-in `Info.plist` version values are not required to change per release.

#### Scenario: Bundle version matches the tag
- **WHEN** the app inside the released DMG built from tag `v0.2.0` is inspected
- **THEN** its `CFBundleShortVersionString` is `0.2.0`

### Requirement: Fail closed when signing credentials are absent
When the signing or notarization secrets required to produce a trusted artifact are unavailable (for example, a run without secret access), the workflow SHALL fail with a clear message rather than publish an unsigned or un-notarized DMG.

#### Scenario: Missing secrets do not yield an untrusted release
- **WHEN** a release run cannot access the Developer ID or notarization credentials
- **THEN** the workflow fails with an explanatory message and no DMG is published to a Release
