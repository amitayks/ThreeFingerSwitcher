# Releasing

Releases are **tag-driven**. Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`, which
builds, **Developer-ID-signs**, **notarizes + staples**, packages a **DMG**, and publishes a
GitHub Release with the DMG attached. Branch pushes never release.

This is a one-time setup of six repository secrets, then `git tag && git push --tags` forever after.

## Prerequisites

- An **Apple Developer Program** membership (you have one).
- A **Developer ID Application** certificate (this is the cert type for notarized direct
  distribution — *not* "Apple Distribution" / "Mac App Distribution").
- An **App Store Connect API key** (used by `notarytool` — cleaner than an Apple-ID app-specific
  password and not tied to your 2FA).

## One-time: create the six repository secrets

Add each under **GitHub repo ▸ Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret**.

### 1–2. Developer ID certificate → `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`

1. In **Keychain Access**, find your **Developer ID Application: …** certificate (with its private
   key). If you don't have one: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ ➕ ▸
   *Developer ID Application*, or create it at <https://developer.apple.com/account/resources/certificates>.
2. Right-click the cert ▸ **Export** ▸ save as `DeveloperID.p12`, set an export password.
3. Base64-encode it:
   ```bash
   base64 -i DeveloperID.p12 | pbcopy      # paste into DEVELOPER_ID_P12_BASE64
   ```
4. `DEVELOPER_ID_P12_PASSWORD` = the export password you just set.
5. Delete the local `.p12` when done.

### 3. `APPLE_TEAM_ID`

Your 10-character Team ID (e.g. `ABCDE12345`), shown at
<https://developer.apple.com/account> ▸ Membership, or:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# → "Developer ID Application: Your Name (ABCDE12345)"
```

### 4–6. App Store Connect API key → `ASC_API_KEY_BASE64`, `ASC_KEY_ID`, `ASC_ISSUER_ID`

1. Go to <https://appstoreconnect.apple.com/access/integrations/api> (needs Admin / Account-Holder).
2. **Generate API Key** with role **Developer** (sufficient for notarization).
3. Download the `AuthKey_XXXXXXXXXX.p8` **once** (Apple won't let you re-download it).
4. Set the secrets:
   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # → ASC_API_KEY_BASE64
   ```
   - `ASC_KEY_ID`  = the key's **Key ID** (the `XXXXXXXXXX` in the filename).
   - `ASC_ISSUER_ID` = the **Issuer ID** (UUID) shown at the top of that API Keys page.
5. Store the `.p8` somewhere safe; delete the local copy from Downloads.

## Cut a release

```bash
# 1. (optional) dry-run with a pre-release tag first:
git tag v0.1.0-rc1 && git push origin v0.1.0-rc1
#    → Actions builds + notarizes; the Release is marked "pre-release".

# 2. real release:
git tag v0.1.0 && git push origin v0.1.0
```

The workflow derives `CFBundleShortVersionString` from the tag (`v0.1.0` → `0.1.0`) and
`CFBundleVersion` from the run number — you do **not** edit `Resources/Info.plist` per release.

## Verify a published artifact (sanity check)

Download the DMG from the Release, then:
```bash
hdiutil attach ThreeFingerSwitcher-0.1.0.dmg
spctl -a -t open --context context:primary-signed -v "/Volumes/ThreeFingerSwitcher 0.1.0/ThreeFingerSwitcher.app"
codesign --verify --deep --strict --verbose=2 "/Volumes/ThreeFingerSwitcher 0.1.0/ThreeFingerSwitcher.app"
xcrun stapler validate ThreeFingerSwitcher-0.1.0.dmg
hdiutil detach "/Volumes/ThreeFingerSwitcher 0.1.0"
```
All four should pass: Gatekeeper accepts it, the signature is valid + sealed, and the
notarization ticket is stapled (works offline).

## Troubleshooting

- **Toolchain gate fails** (`Swift X < required 6.2`): the runner's Xcode is too old for the
  package's `swift-tools-version`. Bump `runs-on:` / the Xcode selection step in the workflow.
- **`notarytool` says Invalid / rejected:** run `xcrun notarytool log <submission-id> --key …`
  to see why. Most common causes are a missing **secure timestamp** or **hardened runtime** on
  some nested code — `build-app.sh` adds both to every signature when `NOTARIZE=1`.
- **"missing secrets" failure:** the workflow fails closed on purpose — it will not publish an
  unsigned DMG. Add the missing secret(s) above and re-run / re-tag.
- **Library-validation crash at launch under hardened runtime:** the entitlements already set
  `com.apple.security.cs.disable-library-validation` (needed to load the third-party
  `OpenMultitouchSupport` framework); keep it.

## Why not the Mac App Store?

The app loads the private `MultitouchSupport` framework, calls private CGS/SkyLight symbols,
runs **unsandboxed**, and drives other apps via Accessibility. Each is an automatic App Store
rejection (sandbox mandatory; private-API ban 2.5.1). Developer-ID + notarization is the correct
and best-eligible channel for this class of utility — same as AltTab, yabai, Rectangle, and
BetterTouchTool.
