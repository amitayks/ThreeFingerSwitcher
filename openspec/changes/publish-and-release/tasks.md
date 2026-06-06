## 1. App icon in the bundle (no secrets; locally verifiable)

- [x] 1.1 Add `Resources/AppIcon.icns` to the repo, sourced from `IconKitchen-Output/macos/AppIcon.icns`
- [x] 1.2 Add `<key>CFBundleIconFile</key><string>AppIcon</string>` to `Resources/Info.plist` (additive — coordinate with `four-finger-launcher`)
- [x] 1.3 In `scripts/build-app.sh`, copy `Resources/AppIcon.icns` → `$APP/Contents/Resources/AppIcon.icns` during assembly
- [x] 1.4 Verify the assembled bundle carries `AppIcon.icns` + `CFBundleIconFile=AppIcon` (verified; final Finder/Get-Info visual is confirmed on the user's stable-signed build)

## 2. Brand assets (logo → menu-bar template mark)

- [x] 2.1 Commit the logo source to `Resources/Branding/z96ck01.svg` (three-bar mark; replaced the earlier two-window `GK38V01.svg`)
- [x] 2.2 Write `scripts/make-icon-assets.sh`: render the SVG onto a square canvas (padded) → template PNGs at `@1x` (18²), `@2x` (36²), `@3x` (54²), alpha-only
- [x] 2.3 Run the script; commit the generated menu-bar template PNG set under `Resources/Branding/`
- [x] 2.4 Preview the mark at 18 pt (three solid bars, square — squared the SVG viewBox first so QuickLook's square thumbnail doesn't aspect-fill-crop the third bar; reads at all sizes — design D6)
- [x] 2.5 In `scripts/build-app.sh`, copy the menu-bar template mark set into the app bundle resources

## 3. Status item uses the brand mark

- [x] 3.1 In `StatusItemController.swift`, load the bundled brand template image (replace `NSImage(systemSymbolName: "rectangle.3.group", …)`)
- [x] 3.2 Set `button.image?.isTemplate = true`; keep the accessibility description
- [x] 3.3 Compiles + previewed legible on light/dark; final in-menu-bar visual confirmed on the user's stable build

## 4. DMG packaging (scripted, repeatable)

- [x] 4.1 Write `scripts/package-dmg.sh`: take a built `.app`, stage a temp folder with the app + an `/Applications` symlink, and `hdiutil create -format UDZO` a compressed DMG
- [x] 4.2 Parameterize output name/version and the volume name; fail clearly if the input `.app` is missing
- [x] 4.3 Verified locally: DMG mounts and contains `ThreeFingerSwitcher.app` + the `/Applications` link (drag-install) — agent build removed afterward

## 5. Version injection from the tag

- [x] 5.1 In `scripts/build-app.sh`, support optional `MARKETING_VERSION` / `BUILD_VERSION` env vars that `plutil`-patch the **copied** bundle `Info.plist` only (leave the repo `Info.plist` untouched)
- [x] 5.2 Verified: `MARKETING_VERSION=0.2.0 BUILD_VERSION=42` → bundle shows `0.2.0`/`42` while repo `Info.plist` stayed `0.1.0`/`1`

## 6. CI release workflow

- [x] 6.1 Add `.github/workflows/release.yml` triggered on tags matching `v[0-9]+.[0-9]+.[0-9]+*`; `runs-on: macos-15` (or newer)
- [x] 6.2 Pin/select Xcode explicitly and print `swift --version` as an early fail-fast toolchain gate (design D7)
- [x] 6.3 Import the Developer ID Application identity from a base64 `.p12` secret into an ephemeral keychain; unlock it for `codesign`
- [x] 6.4 Build + sign via `build-app.sh` with `SIGN_ID` (Developer ID) and `NOTARIZE=1` (hardened runtime), injecting the version from the tag (also fixed `build-app.sh` to add a secure `--timestamp` + hardened runtime to the **nested framework** under `NOTARIZE=1`, else Apple rejects)
- [x] 6.5 Package the DMG via `scripts/package-dmg.sh`
- [x] 6.6 Notarize the DMG with `xcrun notarytool submit --wait` using an App Store Connect API key (key id / issuer / `.p8` from secrets), then `xcrun stapler staple` the DMG
- [x] 6.7 Publish a GitHub Release for the tag and attach the stapled DMG (`softprops/action-gh-release@v2`)
- [x] 6.8 Add an `always()` cleanup step that deletes the temporary keychain; ensure no secret is echoed (no `set -x` around credentials; `::add-mask::` on the identity)
- [x] 6.9 Fail-fast guard: if required signing/notarization secrets are absent, stop with a clear message and do not publish an unsigned DMG (design D8 / spec "fail closed")

## 7. Secrets, dry-run, and verification

- [x] 7.1 Documented repo secrets + full release/verify guide in `docs/RELEASING.md` (configuring the actual secret values in GitHub is the maintainer's to do)
- [ ] 7.2 **(user)** Dry-run with a pre-release tag (e.g. `v0.1.0-rc1`); confirm the Release gets a signed+notarized+stapled DMG
- [ ] 7.3 **(user)** Validate the artifact: `stapler validate`, `spctl -a -t open --context context:primary-signed`, and `codesign --verify --deep --strict` pass on the app inside the DMG
- [ ] 7.4 **(user)** Confirm a branch push produces no Release (trigger correctness)

## 8. Documentation

- [x] 8.1 Added a centered logo + "Download the latest release (.dmg)" link to the `README.md` header and refreshed the Job A install bullet
- [x] 8.2 Added the honest "notarized direct download, not the Mac App Store (sandbox-off + private frameworks)" note
- [ ] 8.3 **(user)** Tag `v0.1.0` for the first real release once the dry-run is green
