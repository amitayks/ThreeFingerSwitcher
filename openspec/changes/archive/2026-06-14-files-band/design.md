## Context

The four-finger launcher already hosts two kinds of band: authored favorites (an icon grid) and the synthetic **Clipboard band** (a master-detail list appended at launcher-open time). The Files band is a third kind: a **local-only Finder-mimic column navigator** you land on like Clipboard and then *drill into* — navigating folders, previewing, and opening/Open-With'ing files entirely by trackpad.

The grounding pass (four read-only readers over the live tree) established that:

- There is **no band-type enum or registry**. A synthetic band is recognized by a sentinel `bandID` UUID on the `ContextBand` **plus** an integer index threaded separately through `show(...) → LauncherModel.setBands(...)`; all view/navigation/sizing switches key off an index-derived boolean (`currentBandIsClipboard`). The Files band must replicate that pattern exactly with its own `filesBandIndex` / `currentBandIsFiles`.
- The recognizer **latches finger count at gesture start** with no mid-gesture morph; the one sanctioned exception is the AI canvas-resolution mode, which flips a flag (`launcherCanvasResolutionActive`) checked as the **first statement** of `feed()` to route into a separate tracker. The Files drill-in is a second such bypass.
- The overlays use **no springs, no `matchedGeometryEffect`** today — every animation is `easeOut`/`linear`, and highlights are a **single persistent sliding view** (per-row highlights were removed because they strobe). The bubble-morph is the first spring in the codebase.
- The open / preview / Open-With surface is mostly present to reuse (`NSWorkspace.open`, the private `FilePreview` QuickLook view, the AI-canvas defuse lifecycle); the **only missing API** is "apps that can open *this* file" → `NSWorkspace.urlsForApplications(toOpen:)`.

Constraint inherited from the app: the overlay panel is **non-activating** and must never become key/main; it is recreated on `show()` and torn down on `hide()`. Errors follow the established AI taxonomy (map at the boundary, surface bounded + non-blocking, never silent).

## Goals / Non-Goals

**Goals:**
- Reach, preview, open, and Open-With any **local** file by trackpad, from inside the launcher, without visiting Finder or touching a mouse.
- A bounded-width **column navigator** (icon-rail ancestors + one current list + one live preview) that scales to any depth.
- A complete, closed **drill-in grammar** (horizontal = depth, vertical = highlight, +1-finger = Open-With, four-finger swipe = discard) layered cleanly on the existing recognizer via a modal bypass. *(Amended: the original "very-up = search" was removed — see D5.)*
- A **bubble-morph** presentation where nothing ever pops; the hero move is the current list collapsing into / blooming out of its ancestor icon.
- A pure, **testable** navigation core (`swift test`), with the MLX split untouched.

**Non-Goals (v1):**
- File operations (move / rename / delete / trash / copy / tag) — navigation and open only; the navigator never mutates the filesystem.
- iCloud / network / placeholder locations — local only (they would also blow the latency budget).
- Non-filesystem providers (Mail, Safari, arbitrary apps) — out of scope; the provider seam is intentionally not generalized in v1.
- A new permission, a native-gesture relocation, or a re-login — the band is a pure software opt-in.

## Decisions

### D1 — Synthetic band via sentinel-id + threaded index, not a band-type enum
Mirror Clipboard exactly: a `FilesBandBuilder` with its **own** sentinel `bandID`, a `filesBandIndex` threaded through the overlay, and a `currentBandIsFiles` boolean gating the view branch, panel sizing, and navigation. *Alternative considered:* introduce a real band-type enum/registry. Rejected — none exists, it would be a broad refactor touching every band site, and the index-boolean pattern is the proven precedent.

### D2 — `.fileEntry` is an ephemeral `LaunchItemKind`, like `.clipboardEntry` (not `.aiCommand`)
The Files band is rebuilt from the live filesystem on every open and is **never persisted**. Add a `.fileEntry` case modeled on `.clipboardEntry` (synthetic, excluded from the editor and persistence), with a **stable identity derived from the absolute path** so re-listings don't strobe the highlight. *Alternative:* persist file items as first-class (like `.aiCommand`). Rejected — it would corrupt the favorites store with transient filesystem state.

### D3 — Drill-in is a sustained modal bypass cloning the canvas-resolution mode
Add `filesDrillActive` to the recognizer and a **second early short-circuit** at the top of `feed()` (right after the canvas check) routing to a new sustained `trackFilesDrill`. Entry/exit are driven by the controller flipping the flag (the `onCanvasStateChanged` wiring pattern). *Alternative:* allow a true mid-gesture morph in the normal latch. Rejected — it violates the load-bearing "no mid-gesture morph" rule; the flag-bypass is how the codebase already does modal sub-states.

### D4 — Open-With trigger is a *relative* +1 finger, not an absolute three
Because the launcher lives while ≥2 contacts remain (you relax four → two), "+1 finger" must mean **a contact was added above the current relaxed baseline** (`count > drillContacts`), not "exactly three." A user holding three the whole time would otherwise false-trigger. *Alternative:* key off absolute count 3. Rejected — ambiguous against the relax-to-two baseline.

### D5 — Type-to-filter search REMOVED (amendment); top-of-list up just clamps
*Originally:* a top-of-column up "very up" clamp-overflow focused a type-to-filter search field (a controller/model decision, since the recognizer has no notion of "row 0"). **This was removed post-implementation:** the search field broke the app's "pure trackpad, no keypresses" model, required the overlay panel to become key-interactive (a focus-vacuum landmine), and went unused. The recognizer still emits `highlight(+1)` past the top; the model now simply **clamps** the highlight at index 0 with no side effect. The Files navigator is pure-trackpad and the panel never becomes key. *(The recognizer was never coupled to list bounds — that part of the original decision still holds.)*

### D6 — Horizontal is the depth axis; layout is icon-rail + current + preview (not full Miller columns)
The user chose horizontal-in/out over lift-to-descend, and a **bounded** layout (ancestors collapse to a thin icon rail; only the current list and one preview are full-size) over classic Miller columns. This reuses the app's existing icon-rail idiom (Hub sidebar, launcher band strip) and keeps overlay width constant at any depth. The preview is *where you're going* (folder → contents peek), so descending = promoting the preview to current. *Alternatives:* lift-to-descend single column (simpler, but leaves "ascend" homeless) and full Miller columns (unbounded width). Both rejected.

### D7 — Lift-to-open with a defusable commit (NOT the AI-canvas swipe-to-resolve)
Lifting on a highlighted entry **opens** it (file → default app, folder → Finder window) on the current Space; the open is **defusable** for a brief fuse so a four-finger horizontal swipe-away before it fires opens nothing, and a relative **+1-finger** lift opens the **Open-With picker** instead. This is the user's stated vision almost verbatim — "landing on the fourth file … the file opened"; "adding another finger, three as all, and then lifting them all … a popup list opened … i can vertically move between the app"; "adding to four fingers and swip away horizontally … even mid opening a file, the app will kill that process". Defuse cancels a **pending** open only — it **never terminates an already-running app**. *Alternative considered & rejected:* the AI canvas's swipe-to-resolve (lift holds, then a fresh down-swipe commits). The canvas holds because you must **review a generated result** before applying it — but a file open has nothing to review, so holding would only add friction over the lift-to-open the user described. The CLAUDE.md "swipe-to-resolve, not lift-to-commit" landmine is **specific to the AI preview canvas** and does not generalize to a navigation surface. (Corrected after Stage 2 implementation surfaced the drift between this design and the user's vision.)

### D8 — One reusable `BubbleMorph` modifier; the moving highlight stays singular
Add `Overlay/BubbleMorph.swift`: a `ViewModifier` doing `scaleEffect(0.02 → 1, anchor:)` + opacity on a `spring(response: 0.34, dampingFraction: 0.72)` — the first spring in the app — applied to **containers / rows / preview / menus, never leaf glyphs**. Depth reveal uses the `SwitcherView` `.id`/`.transition` idiom but **scaling, not sliding**. The single sliding selection highlight is **not** bubble-morphed (per-row morphs reintroduce the documented scrub strobe). Because the panel is torn down wholesale on `hide()` (no SwiftUI removal transition), a receding exit needs the controller to **animate `shown = false` then delay `close()`**; the panel is sized to its **final** frame for a depth up-front (AppKit `NSAnimationContext` resize runs on a different clock than the SwiftUI spring). No new haptics — the `.alignment` arm tick stays the only one.

### D9 — Reuse the open/preview surface; add exactly one API
- **List:** `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:[.isDirectoryKey,.contentModificationDateKey,.isRegularFileKey])` on a detached `userInitiated` task.
- **Preview:** promote the private `FilePreview` (QuickLook `QLThumbnailGenerator`, icon fallback) to internal and embed it.
- **Open:** `NSWorkspace.open(url)` (default) / `open([url], withApplicationAt:, configuration:)` (Open-With + failure-surfacing); the new window lands on the current Space natively — **do not** route through `SpaceWindowMover`.
- **Open-With enumeration (new):** `NSWorkspace.urlsForApplications(toOpen: url)`; default app via `urlForApplication(toOpen:)`; map to the existing `AppCandidate`.

### D10 — Capability decomposition mirrors Clipboard's
`files-band` (new) owns the **domain**: opt-in/injection, roots + remembered locations, on-demand listing, the navigation state machine, open/Open-With/defuse, and error mapping. `launcher-overlay` (delta) owns the **view/interaction**: layout, depth/highlight nav, preview, swipe-to-resolve, bubble-morph. `gesture-recognition` (delta) owns the recognizer **mechanism**. `configuration-hub` (delta) owns the **Files page**. This matches how Clipboard splits across `clipboard-history` (data) and `launcher-overlay` (view).

## Risks / Trade-offs

- **Eyes-on, not blind muscle memory.** The Files band is read-and-pilot, unlike the positional launcher → *Mitigation:* it's an explicit opt-in and a visually distinct surface (column navigator, not a grid); the two modes never masquerade as each other.
- **Type-to-filter breaks "pure trackpad."** → *Resolved by removal (amendment):* search was cut entirely; the navigator is trackpad-only with no exception, so this risk no longer applies.
- **Scroll-tap vs. a real scroll view.** While the overlay is visible the session scroll tap swallows two-finger scroll → *Mitigation:* the current list is navigated by **gesture stepping + edge auto-repeat** (gesture-scrolled), so no carve-out is needed; only if a genuine `ScrollView` is introduced do we add a `filesDrillActive` carve-out **and** flip the panel key-interactive (mirroring the AI path).
- **Panel-resize / spring clock desync.** AppKit frame resize and the SwiftUI spring run on different clocks → *Mitigation:* size the panel to the depth's **final** frame up-front; the bubble morphs *inside* the settled frame.
- **Defuse cannot un-ring the bell.** Once an app has actually launched, discard can't cancel it → *Mitigation:* honest scope — defuse cancels only the **pending** open within the fuse/held window; it never kills a running app. Documented as a limit, not a bug.
- **Phantom steps on relax/add.** Leaving/landing fingers shift the centroid → *Mitigation:* mandatory re-baseline of origin + carry on **every** contact-count change (copied from the launcher tracker).
- **Highlight strobe.** Re-created per-row highlights flicker during fast scrub → *Mitigation:* keep the moving highlight a single sliding element; bubble only content/structure.
- **Latency budget.** AX-scraped providers would be slow → *Mitigation:* local filesystem only (fast); non-FS providers are explicit non-goals.

## Migration Plan

Purely **additive** and **opt-in (default off)** — no data migration, no schema change to persisted favorites (the `.fileEntry` kind is never written to disk), no permission, no native-gesture relocation, no re-login. The MLX/`GemmaRuntime` split is untouched. **Rollback** is turning the opt-in off (removes the band on next open) or reverting the change; nothing persists that would outlive it. Ship behind the opt-in; verify Core logic via `swift build`/`swift test` and the MLX-linked app via `xcodebuild` compile-check.

## Open Questions

- **Default seed roots** — ship a sensible default set (e.g. Home, Desktop, Downloads, Documents) or start empty and prompt? Leaning: seed a small default, fully editable on the Files page.
- **Folder default-open semantics** — confirmed: default open of a folder = a Finder window; *descending* is the horizontal gesture (the two are distinct). Revisit only if it feels redundant in the hand.
- ~~**Search scope**~~ — moot: type-to-filter search was removed entirely (see D5 / the amendment). The navigator is pure-trackpad.
- **Very-large folders** — does a single `contentsOfDirectory` read stay within budget for huge directories, or do we need windowed loading + a "…more" affordance? Resolve during implementation against real directories.
- **Bubble-morph anchor per surface** — columns may want `.leading`/`.trailing` (bud from the attachment edge) rather than `.center`; pick per surface during view build.
