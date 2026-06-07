## Context

The repo builds a menu-bar agent via SwiftPM + `scripts/build-app.sh`, which already assembles, rpaths, and **signs** the `.app` (stable self-signed "ThreeFingerSwitcher Dev" cert locally, ad-hoc fallback) and has dormant `SIGN_ID` / `NOTARIZE=1 → --options runtime` hooks. There is no app icon asset, no `CFBundleIconFile`, no CI, and no git tags. The `menubar-app-shell` spec already states the app ships as a "direct, notarized download," so this change *fulfills* an existing commitment rather than inventing one.

Two provided inputs: `IconKitchen-Output/macos/AppIcon.icns` (valid `ic11`, ready) and the menu-bar logo SVG (`z96ck01.svg` — a 3-path, solid-filled **three-bar** mark, **landscape ≈1.43:1**; it superseded an earlier two-window outline). The user has an Apple Developer account → Developer ID + notarization is on the table; the Mac App Store is not (sandbox-off + private frameworks). Distribution asset chosen: **DMG**.

A second agent is concurrently implementing `four-finger-launcher` (touches app code + possibly the version). The only file this change shares with it is `Info.plist`.

## Goals / Non-Goals

**Goals:**
- App carries a real icon in the bundle (Finder / Spotlight / login-items / Accessibility list).
- Menu-bar status item shows the project's own mark instead of a stock SF Symbol.
- One `git tag vX.Y.Z && git push --tags` produces a **Developer-ID-signed, notarized, stapled DMG** attached to a GitHub Release — double-click install, no Gatekeeper fight.
- Reproducible, scripted asset + DMG generation (no manual Finder/Disk-Utility steps).
- Local dev build flow (`build-app.sh` with the self-signed cert) stays exactly as it is.

**Non-Goals:**
- Mac App Store submission (architecturally impossible — documented, not attempted).
- Auto-update / Sparkle feed (future; out of scope here).
- Homebrew cask (could follow once Releases exist; not in this change).
- Changing any runtime switcher behavior.

## Decisions

### D1 — Trigger: version tag `vX.Y.Z`, not every push
Releases fire on annotated tags matching `v[0-9]+.[0-9]+.[0-9]+`. Rationale: a release is an intentional, versioned act; "every push to main" produces noise and non-versioned artifacts. The tag is the single source of truth for the version. *Alt considered:* push-to-main + rolling "nightly" pre-release — deferred (can be added later as a second workflow without disturbing this one).

### D2 — Signing on CI: import Developer ID into an ephemeral keychain
The workflow base64-decodes the `.p12` from a secret, creates a temporary keychain, imports the identity, unlocks it for `codesign`, and deletes it on cleanup (always, even on failure). `build-app.sh` is invoked with `SIGN_ID="Developer ID Application: … (TEAMID)"` and `NOTARIZE=1` (the latter enables `--options runtime`, required for notarization). *Alt considered:* a self-hosted signed runner — rejected (infra overhead for a solo OSS project). *Alt:* signing the default login keychain — rejected (pollutes the runner, harder cleanup).

### D3 — Notarization: App Store Connect API key, stapled
Use `xcrun notarytool submit --wait` with an **App Store Connect API key** (`AUTH_KEY` .p8 + key id + issuer id) over the legacy Apple-ID + app-specific-password path — API keys are revocable, scoped, and don't tie to a person's 2FA. Notarize the **DMG** (notarytool accepts dmg/zip/pkg), then `xcrun stapler staple` the DMG so the ticket travels offline. Notarization scans for malware + hardened-runtime + valid Developer-ID signature; it does **not** reject private frameworks (that's an App Store concern), so this app notarizes cleanly. *Alt:* notarize the `.app` inside a zip then build the DMG — more steps; stapling the DMG directly is simpler and what users download.

### D4 — DMG: scripted via `hdiutil`, with an `/Applications` symlink
`scripts/package-dmg.sh` builds a read-only compressed DMG (`hdiutil create -srcfolder … -format UDZO`) containing `ThreeFingerSwitcher.app` + a symlink to `/Applications` for drag-install. Keep it dependency-free (pure `hdiutil`) rather than pulling `create-dmg`; a fancy background/layout can come later. The DMG is signed-content-only (the stapled `.app` inside carries trust); the DMG itself is also notarized+stapled per D3.

### D5 — Version injected from the tag at build time
CI strips the leading `v` from the tag → `CFBundleShortVersionString`; `CFBundleVersion` gets a monotonically increasing integer (the run number, or commit count). `build-app.sh` gains optional `MARKETING_VERSION` / `BUILD_VERSION` env vars that `plutil`-patch the copied `Info.plist` *in the assembled bundle only* (the repo `Info.plist` is left at its dev value to avoid churn and merge conflicts with `four-finger-launcher`).

### D6 — Menu-bar mark: square the viewBox, then QuickLook + luminance→alpha
The status bar wants a ~square ≤18 pt template mark; the source logo (`z96ck01.svg`, three solid bars) is 1.43:1 landscape. `scripts/make-icon-assets.sh` produces an alpha-only template PNG set (`@1x` 18²/`@2x` 36²/`@3x` 54², `isTemplate = true`) so macOS recolors it for light/dark. Two non-obvious problems forced the approach:
- **AppKit `NSImage` mis-parses these potrace SVGs** (a `<g transform>` with sub-paths) — it fills them solid. So we rasterize through **QuickLook's WebKit** renderer (`qlmanage`) instead, then convert the black-on-white render to alpha = 1 − luminance, trimming whitespace. A modest alpha gain (≈1.6) firms thin features; solid fills clamp harmlessly.
- **QuickLook's thumbnail is square and aspect-*fill* CROPS a landscape logo** — it sliced off the third (rightmost) bar, leaving only two. Fix: the script first pads the SVG's own `viewBox` to a centred **square** (generic: reads `minx miny w h`), so QuickLook renders the full mark uncropped.
The generated PNGs are committed so the app build needs no SVG toolchain. The colorful app icon (`AppIcon-256.png`) — not this mark — is used for the README header (the template mark is white/invisible on a page).

### D7 — Toolchain pinning on the runner
`Package.swift` is `swift-tools-version: 6.2`. The workflow pins `runs-on: macos-15` (or newer) and selects Xcode explicitly via `xcode-select` / `maxim-lobanov/setup-xcode` to a version whose Swift ≥ 6.2; the job prints `swift --version` early so a toolchain mismatch fails loudly at the top, not mid-build.

### D8 — Secrets absent ⇒ fail fast, never publish unsigned
All signing/notarization inputs come from repo **secrets** (never echoed; `set -x` avoided around them). If a required secret is missing (e.g. a fork without access), the workflow **fails fast with a clear message** rather than publishing an unsigned/un-notarized DMG that would mislead users into a Gatekeeper trap. A release artifact is notarized or it doesn't exist.

## Risks / Trade-offs

- **Notarization rejects the app** → Mitigation: it shouldn't — private frameworks are an App-Store-only block; we ship hardened-runtime + Developer-ID + secure timestamp, which is all notarytool checks. The `--wait` log surfaces any issue; the existing entitlements (no `get-task-allow`) are notarization-clean.
- **Leaking the Developer ID cert in CI logs** → Mitigation: secrets only, temp keychain deleted in an `always()` cleanup step, no `set -x` near credential handling, `.p12` passed via env not argv.
- **Swift 6.2 unavailable on the runner image** → Mitigation: pin image + explicit Xcode select; fail-fast `swift --version` gate (D7).
- **Landscape logo unreadable at 18 pt in the menu bar** → Mitigation: square-pad + preview; documented fallback to a simplified glyph (D6). Does not block the icns/app-icon work, which is independent.
- **Merge conflict with `four-finger-launcher` on `Info.plist`** → Mitigation: our only `Info.plist` edit is the additive `CFBundleIconFile` key; version stays dev-valued in-repo (D5). Trivial to rebase.
- **First Gatekeeper "downloaded from internet" prompt still appears** → Accepted: that one-time prompt is normal for *all* notarized direct downloads; it is not the blocking "unidentified developer" wall. README sets the expectation.

## Migration Plan

1. Land branding (icns + Info.plist key + `build-app.sh` copy + status-item mark) — verifiable with a local `build-app.sh`; no secrets needed.
2. Add `make-icon-assets.sh` + `package-dmg.sh`; verify a DMG opens and drags to Applications locally.
3. Add `.github/workflows/release.yml`; configure repo secrets (Developer ID `.p12`+pw, ASC API key/issuer/key-id).
4. Dry-run: push a `v0.1.0-rc1` pre-release tag; confirm signed+notarized+stapled DMG appears on the Release; `spctl -a -t open --context context:primary-signed` and `stapler validate` pass.
5. Tag `v0.1.0` for the first real release; update README Download link.
- **Rollback:** delete the Release + tag; the pipeline is additive and touches no runtime code, so reverting the branch fully restores prior state.

## Open Questions

- App Store Connect **API key** vs Apple-ID app-specific password for notarytool — design assumes API key (D3); confirm the account can mint one (Admin/Account-Holder role).
- DMG cosmetics (custom background, icon layout, window size) — deferred; plain `hdiutil` DMG ships first.
- Whether to also publish the raw `.app.zip` alongside the DMG for scripting/Homebrew later — not in this change.
