## 1. Remove the setting

- [x] 1.1 `AppSettings`: remove the `livePreviewEnabled` published property + doc, its `Defaults` entry, its `Keys` entry, the init read, and the reset-to-defaults line.

## 2. Make the live-preview loop unconditional

- [x] 2.1 `AppCoordinator.startLivePreview`: drop the `settings.livePreviewEnabled` clause from the guard (keep `overlay.isVisible`); update the doc.
- [x] 2.2 `AppCoordinator.tickLivePreview`: remove the `guard settings.livePreviewEnabled` line; update the doc.
- [x] 2.3 `AppCoordinator`: remove `observeLivePreviewToggle()` and its call site in setup (nothing to react to).

## 3. Remove the UI

- [x] 3.1 `HubFeaturePages`: remove the "Live preview of the highlighted window" toggle from the Switcher → Behavior section.

## 4. Specs + verify

- [x] 4.1 `swift build --target ThreeFingerSwitcherCore` && `swift test` green (903 tests, 0 failures); no leftover `livePreviewEnabled` / `observeLivePreviewToggle` references.
- [x] 4.2 `openspec validate remove-live-preview-toggle --strict`.
- [ ] 4.3 In-app: confirm there is no live-preview toggle on the Hub Switcher page, live preview runs whenever the switcher is open, and the previously stuck-off machine now shows live previews. _(Needs the signed app — your Terminal.)_
- [ ] 4.4 Sync the deltas into `switcher-overlay` / `tunable-settings` / `window-enumeration-and-raising` and archive. _(After 4.3 confirms in-app.)_
