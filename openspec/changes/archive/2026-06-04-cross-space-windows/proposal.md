## Why

The switcher only lists windows on the current Space (confirmed on-device), violating the `window-enumeration-and-raising` spec ("across all Spaces"). Root cause (verified): `WindowService.snapshot()` enumerates only via `AXUIElementCreateApplication(pid)` + `kAXWindowsAttribute`, which on macOS 12.2–26 materializes window elements **only for Spaces currently realized for that process**. `CGWindowListCopyWindowInfo(.optionAll)` is **not** an all-Spaces source either. Getting all-Spaces windows — and raising one that lives on another Space — requires the private CoreGraphicsServices/SkyLight APIs that AltTab uses.

## What Changes

- **Enumerate across all Spaces**: build the candidate window set from private CGS per-Space enumeration (`CGSCopyManagedDisplaySpaces` + per-Space `CGSCopyWindowsWithOptionsAndTags`), correlate to AX elements, and include other-desktop and native-fullscreen windows (and windows/Spaces that existed before launch). Minimized excluded; current-Space behavior unchanged.
- **Raise off-Space windows**: acquire a valid AX element for off-Space windows via brute-force `_AXUIElementCreateWithRemoteToken`, then front+key-focus via `_SLPSSetFrontProcessWithOptions` + a `SLPSPostEventRecordTo` key sequence + `kAXRaiseAction`, causing exactly one Space switch — only at commit.
- **Crash-safety**: resolve every private symbol via `dlsym` at startup (the CGS/SLS symbols live in `SkyLight.framework`, which is not auto-linked; a missing `@_silgen_name` symbol would abort at launch). If any symbol is missing, `offSpaceSupported = false` and enumeration/raise fall back to today's exact current-Space behavior — never regress, never crash.
- Thumbnails already work off-Space (no functional change).

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `window-enumeration-and-raising`: enumeration now spans all Spaces; raising supports off-Space windows with a single Space switch on commit; both degrade safely to current-Space-only when private APIs are unavailable.

## Impact

- New files: `Sources/ThreeFingerSwitcher/Windows/CGSPrivate.swift`, `Sources/ThreeFingerSwitcher/Windows/Spaces.swift`.
- Edits: `WindowService.swift` (snapshot + raise rewrite, keep `legacySnapshot()`), `AXPrivate.swift` (remote-token brute force), `WindowInfo.swift` (`axElement` optional + `isOnCurrentSpace`/`spaceID`), `ThumbnailService.swift` (comment), `AppCoordinator.swift` (compile against optional element).
- Private APIs (all `dlsym`-resolved, degrade if absent): `CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `CGSManagedDisplayGetCurrentSpace`, `CGSCopyWindowsWithOptionsAndTags`, `_AXUIElementCreateWithRemoteToken`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`; Carbon `GetProcessForPID` (deprecated). No SwiftPM linker changes (dlsym avoids link-time SkyLight dependency).
- GPL-3 (technique adapted from AltTab). No new user permissions; off-Space titles are app-name-only without Screen Recording when no AX element resolves.
