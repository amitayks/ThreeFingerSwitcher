## Why

The project is going open-source with a public GitHub remote, but it has **no app icon**, **no download**, and **no automated release** — today the only way to get the app is to clone and run `build-app.sh`. The `menubar-app-shell` spec already commits us to shipping "a direct, **notarized** download rather than via the Mac App Store," but nothing fulfills that promise. This change wires a real brand identity into the bundle and stands up a tag-driven CI pipeline that builds, **signs with Developer ID, notarizes, and publishes a DMG** to GitHub Releases — so a user can download and double-click, no Gatekeeper fight and no toolchain.

The Mac App Store is **out of scope and architecturally impossible**: the app loads the private `MultitouchSupport` framework, calls private CGS/SkyLight symbols (`SLSMoveWindowsToManagedSpace`, `_AXUIElementCreateWithRemoteToken`), runs with App Sandbox **off**, and drives other apps via Accessibility — each of which is an automatic MAS rejection (sandbox mandatory, private-API ban 2.5.1). Developer ID + notarization is the correct and best-eligible channel, exactly like AltTab / yabai / Rectangle / BetterTouchTool.

## What Changes

- **Give the app an icon for the first time.** Ship `AppIcon.icns` (from the provided IconKitchen output) in the repo, add `CFBundleIconFile` to `Info.plist`, and copy it into `Contents/Resources/` during assembly. Today the bundle has no icon asset at all, so Finder / Spotlight / the System Settings login-items & Accessibility lists show a generic placeholder.
- **Brand the menu-bar status item.** Replace the generic SF Symbol `rectangle.3.group` with the project's own mark, rendered from the provided logo as a **template image** (alpha-only, so it auto-adapts to light/dark menu bar). The source logo is landscape (≈1.43:1); a square menu-bar variant is derived so it reads at ~18 pt (the full landscape logo is reserved for the README header / About, not the menu bar).
- **Add a tag-driven release pipeline.** A GitHub Actions workflow on a macOS runner triggers on a version tag `vX.Y.Z`, builds the app, signs it with a **Developer ID Application** identity, **notarizes** it via `notarytool` and **staples** the ticket, packages a **DMG** (drag-to-Applications), and publishes it as a GitHub Release asset. The release version is injected from the tag (no hand-edited `Info.plist` per release).
- **Make `build-app.sh` release-capable.** Extend the existing script so its already-present `SIGN_ID` / `NOTARIZE` paths are driven cleanly from CI (Developer ID identity imported into a temporary keychain), it copies the app icon, and it can stamp `CFBundleShortVersionString` / `CFBundleVersion` from the tag. Local self-signed dev builds are unchanged.
- **Document the download.** Add a "Download" section + logo to the README pointing at the latest Release, and an honest one-line "why not the App Store / why notarized" note (the reasoning already half-lives in the README).

## Capabilities

### New Capabilities
- `release-pipeline`: the tag-driven CI/CD flow — on `vX.Y.Z`, build on a macOS runner, sign with Developer ID Application, notarize + staple via `notarytool`, package a DMG, inject the version from the tag, and publish a GitHub Release; signing/notarization credentials supplied as CI secrets, with a graceful failure if they are absent.
- `app-branding`: the app's visual identity in the shipped bundle — `AppIcon.icns` present and referenced by `CFBundleIconFile`, copied into the assembled `.app`; plus the brand asset set (logo source + generated menu-bar template mark) that the app and README consume.

### Modified Capabilities
- `menubar-app-shell`: the status-bar item SHALL present the app's **brand mark** (a template image derived from the project logo) instead of the generic SF Symbol; and the spec's existing "direct, notarized download" distribution posture is now **realized** by the `release-pipeline` capability (DMG, Developer-ID-signed, notarized).

## Impact

- **New files:**
  - `Resources/AppIcon.icns` — the shipped app icon (committed binary).
  - `Resources/Branding/` — the logo source (`z96ck01.svg`, three-bar mark) + generated menu-bar template PNGs (`@1x/@2x/@3x`) + a visible app-icon PNG for the README header.
  - `.github/workflows/release.yml` — the tag-triggered build/sign/notarize/package/publish workflow.
  - `scripts/make-icon-assets.sh` — regenerate the menu-bar template set from the SVG (reproducible asset build).
  - `scripts/package-dmg.sh` — assemble the drag-to-Applications DMG from the built `.app`.
- **Modified files:**
  - `Resources/Info.plist` — add `CFBundleIconFile`; version keys become CI-injectable. *(Shared with the in-progress `four-finger-launcher` change — additive, low-conflict.)*
  - `scripts/build-app.sh` — copy the icon into the bundle; CI-driven Developer ID signing into a temp keychain; optional version stamping from the tag.
  - `Sources/ThreeFingerSwitcher/App/StatusItemController.swift` — load the brand template image (bundle resource) instead of the SF Symbol; `isTemplate = true`.
  - `README.md` — Download section, logo, and the "notarized direct download, not App Store" note.
- **CI secrets required (Developer ID + notarization):** Developer ID Application cert as base64 `.p12` + its password; notarization credentials (App Store Connect API key **or** Apple ID + app-specific password + Team ID). The workflow must not echo these and must degrade gracefully (e.g. fork PRs without secrets do not attempt to sign/notarize).
- **No new app permissions, dependencies, or private symbols.** Runtime behavior of the switcher is unchanged; this is packaging, branding, and distribution only.
- **Toolchain risk (de-risked in design):** `Package.swift` is `swift-tools-version: 6.2`; the macOS runner's Xcode/Swift version must satisfy it (pin the runner image + select Xcode explicitly).
- **Coordination:** the in-progress `four-finger-launcher` instance edits app code and may bump the version; the only shared file here is `Info.plist` (additive icon key). New files do not collide.
