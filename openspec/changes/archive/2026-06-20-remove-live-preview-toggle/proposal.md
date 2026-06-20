## Why

Live preview of the highlighted window is what gives the switcher its dynamic, alive feel — and now that it captures cleanly (the motion gate + K-tick settle + `.fit` keep it from ever grabbing an in-flight / "sideways" frame), there is no longer a reason to keep it behind an opt-in. The toggle also created a real footgun: a reverted "default-off" experiment left some machines with `livePreviewEnabled` persisted **false**, so live preview silently stopped working even though the code default is on — confusing and hard to discover. Making live preview unconditional removes the setting, its UI, its persistence, and that entire class of stuck-off state.

## What Changes

- **Live preview is always on.** Remove the `livePreviewEnabled` setting entirely — the published property, its `Defaults` value, its persistence `Keys` entry, the init read, and the reset-to-defaults line.
- **Remove the UI.** Drop the "Live preview of the highlighted window" toggle from the Hub Switcher → Behavior section.
- **Run the loop unconditionally.** `startLivePreview` / `tickLivePreview` are no longer gated on the setting; the loop starts whenever the switcher overlay opens and stops on teardown exactly as before. Remove the now-purposeless `observeLivePreviewToggle` Combine observer and its call site.
- **No migration.** A persisted `livePreviewEnabled` value simply stops being read, so a machine stuck off from the reverted experiment is fixed automatically; the orphaned UserDefaults key is harmless.

## Capabilities

### Modified Capabilities

- `switcher-overlay`: the "Live preview of the highlighted window" requirement no longer references a setting/toggle — live preview is unconditional; the "toggle off stops re-capture" scenario is removed and a "no toggle" scenario added. The no-sideways guarantees (motion gate, fresh-frame cleanliness, teardown) are unchanged.
- `tunable-settings`: the "Live preview opt-in" tunable is removed.
- `window-enumeration-and-raising`: the refresh requirement's reference to "the live-preview setting fully gates re-capture" is corrected — continuous re-capture is the always-on live-preview path.

## Impact

- **Code:** `Settings/AppSettings.swift` (remove the property/default/key/read/reset), `App/AppCoordinator.swift` (drop the two setting guards + the observer + its call site), `Hub/HubFeaturePages.swift` (remove the toggle row).
- **Behavior:** no new permission, no gesture relocation, no re-login; MLX-free Core, verified under `swift build` / `swift test` (903 tests green). The in-flight "sideways" frame is still prevented by the existing motion gate + K-tick settle + `.fit`.
- **Migration:** none — the orphaned `livePreviewEnabled` default key is ignored, which is what fixes the previously-stuck-off machines.
