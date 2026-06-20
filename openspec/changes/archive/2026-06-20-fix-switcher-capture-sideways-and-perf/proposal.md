## Why

The Mission-Control real-proportion grid (`ecc66e9`) can render a "sideways" (tilted / wrong-aspect) thumbnail for a window for a beat right after it is captured. The clearest repro: switch between two apps (e.g. VSCode → Telegram) and **immediately** open the switcher — a *bystander* window like Terminal is captured while Stage Manager is still animating the stage, and that in-flight frame lands on its card.

The root cause is **capturing a window while macOS is mid-animation**, not a wrong threshold. Stage Manager (and Mission Control) animate a window between the off-stage strip and the full stage with a **perspective + aspect morph**: for part of that animation the window's reported **bounds** are already (near) full size while its rendered **pixels** are still tilted / wrong-aspect. The degraded-capture gate (`isDegradedCapture` / `isStripProxy`, recently raised to `cleanScaleThreshold = 0.85`) is **geometry-only** — it reliably rejects the small/scaled strip phase and the set-aside proxy, but it **cannot** reject a frame whose bounds look normal and only the pixels are mid-morph. That frame passes the gate and gets captured; the card's `.fill` + crop then zooms it to the window's true proportion, turning a harmless letterbox into a glaring sideways smear.

Two capture paths reach a window at the moment of risk:

- the open-time one-shot **`prefetch`**, which re-captures *every* cleanly-visible row window — so a never-highlighted bystander (Terminal) gets clobbered;
- the per-tick **`liveCapture`** of the highlighted window, which today even gates against a **stale** per-gesture snapshot frame, and whose "Live preview" toggle **leaks** — it gates only the idle timer, not the scrub-step capture.

The `0.85` threshold (already landed) is the correct geometry backstop and stays, but it cannot close the tilted-pixels-at-normal-bounds gap. The fix is to **stop capturing while the window is in motion**, keep the live-updating preview, and render any frame that still slips through harmlessly.

## What Changes

- **Motion-gate the capture (primary fix).** A fresh capture SHALL land only when the window's *current* frame has stopped moving (unchanged across consecutive cheap reads). While the frame is still changing — morphing between the strip and the stage, animating to/from the Dock — the window keeps its last good (seeded/cached) frame for as long as the animation runs, then captures cleanly once it settles. The live path SHALL gate on the window's **fresh** bounds, not the stale per-gesture snapshot.
- **Keep live preview ON by default.** The highlighted window still updates live — just never mid-morph. (This change deliberately does **not** default live preview off / stop continuous re-capture; that path was considered and rejected — see design.)
- **The one-shot open prefetch SHALL NOT clobber a good cached frame.** A previously-seen window (Terminal) keeps its good frame instead of being re-captured — possibly mid-animation — when the switcher opens; only a never-seen window is captured (still behind the geometry + motion gate). Fixes the reported bystander case directly.
- **The "Live preview" toggle SHALL fully gate continuous re-capture.** Today it gates only the idle timer; the scrub-step capture fires regardless. With the toggle off, *no* window is re-captured during a gesture.
- **Render `.fit` (letterbox), not `.fill` (crop).** Any transitional frame that still reaches a card is shown reduced, never cropped into a sideways smear; a clean capture (aspect == the card's real-proportion aspect) still fills edge-to-edge, so the Mission-Control look is preserved.
- **Bound capture resolution to the display target.** Cap captures to roughly the on-screen card size × a Retina headroom (≈ 600×400) instead of 1100×700 at full native Retina — restoring capture/composite speed and shortening any bad frame's time on screen.
- **Lighten grid rendering.** Drop the card image `.interpolation(.high)` → `.medium` (invisible at card scale, cheaper per frame, now on a smaller bitmap).

## Capabilities

### New Capabilities

_None — this refines existing behavior._

### Modified Capabilities

- `switcher-overlay`: the "Live preview of the highlighted window" no-sideways guarantee is extended to cover **in-transition** windows — a fresh live capture is withheld while the window is **in motion** (its frame still changing tick-to-tick) and resumes the instant it settles; the toggle fully gates *all* continuous re-capture (not just the idle timer); the real-proportion grid SHALL render `.fit` (letterbox, so a slipped-through frame is harmless) and efficiently (bounded thumbnail bitmaps, lighter resample).
- `window-enumeration-and-raising`: ScreenCaptureKit captures SHALL be sized to the display target rather than full native Retina; the degraded-capture gate SHALL evaluate cleanliness against the window's **current** frame (not a stale snapshot) and SHALL skip a window whose frame is still in motion; the one-shot open refresh SHALL NOT overwrite a window that already has a good cached frame.

## Impact

- **Code:** `Sources/ThreeFingerSwitcher/Windows/ThumbnailService.swift` (fresh-bounds read, motion gate, prefetch don't-clobber, capture sizing), `Sources/ThreeFingerSwitcher/App/AppCoordinator.swift` (gate the scrub-step `tickLivePreview` on the toggle), `Sources/ThreeFingerSwitcher/Overlay/SwitcherView.swift` (`.fill` → `.fit`, interpolation `.high` → `.medium`), and their unit tests (`OffSpaceFidelityTests` / `SwitcherLayoutTests`).
- **Already landed (do not redo):** `cleanScaleThreshold = 0.85` + the `||` (either-dimension) geometry gate, with `OffSpaceFidelityTests` cases. This is the only surviving change from the earlier exploration — every other approach (fixed settle, aspect gate, `.fit`, live-preview-default-off) was reverted from code and is re-scoped here only where it is part of B+C.
- **Behavior:** no new permission, no gesture relocation, no re-login; MLX-free Core, so it verifies under `swift build` / `swift test`. Live preview stays on by default.
- **Risk:** the motion gate relies on `CGWindowList` reflecting the Stage-Manager animation (bounds changing tick-to-tick); if a future macOS reported perfectly static bounds through an animation, the `.fit` render + geometry gate remain as backstops. Validated against `TFS_THUMB_LOG` data before locking.
