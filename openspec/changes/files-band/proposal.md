## Why

macOS makes you leave what you're doing to reach a file: switch to Finder, click through folders, open it, switch back. The four-finger launcher already proved you can reach favorites by positional muscle memory without lifting a hand to the keyboard or mouse — but today it can only *fire static targets*, not *navigate*. The Files band extends that reach into the live local filesystem: drill to any file, preview it, open it, or hand it to a specific app — entirely by trackpad, without ever visiting Finder or touching a mouse.

## What Changes

- A new **Files band** inside the four-finger launcher (opt-in, default off), injected the way the Clipboard band is — you *land* on it and you are in a live, **local-only** Finder-style navigator. No gesture relocation, no re-login, no new permission (it reads the filesystem on demand).
- **Configured roots** (set in the Hub) form the entry column; each root remembers where you left off; backing fully out returns to the roots list.
- A **column-navigator** layout: a thin icon rail of ancestors **+** one full current-folder list **+** one live preview. Descending collapses the current column *into* its breadcrumb icon and buds the child up; ascending blooms the parent icon back into the full column. The preview is *where you are going* (file → Quick Look, folder → a peek of its contents), so descending promotes the preview to current.
- A **drill-in gesture grammar** (two fingers while in the band): horizontal = depth (into / out of folders), vertical = move the highlight, vertical past the top ("very up") = focus search, lift = open for real and leave, **+1 finger then lift = Open-With** (only the apps that can open this file), four-finger swipe-away = discard.
- **Quick Look preview**, **open-in-default** (the new window lands on the current Space, never teleporting you away), and a **defusable open** resolved by the existing swipe-to-resolve convention (a fresh four-finger *down* swipe commits, *horizontal* discards) so an in-flight open can be cancelled.
- A **bubble-morph animation law**: nothing ever appears at full presence — every column, row, preview, and menu scales-and-fades up from a near-zero droplet on a soft spring and recedes the same way on leave. This introduces the first spring-based motion in the app.
- A **Hub surface** to customize appearance (column width/density, tint, icon-vs-preview) and behavior (the roots list, sort order, default-open action, which metadata shows).
- Type-to-filter search is the **single, deliberate, scoped** relaxation of the app's "pure trackpad, no keypresses" rule — confined to the search field.
- **Scoped out of v1 (non-goals):** file operations (move / rename / delete / tag), iCloud / network locations, and any non-filesystem provider. The seam is built so they can come later.

## Capabilities

### New Capabilities
- `files-band`: the in-launcher, local-only Finder-mimic file navigator — its opt-in entry and injection, configured roots with remembered locations, the icon-rail + current-column + live-preview layout, the semantics of the drill-in grammar, Quick Look preview, open-in-default and Open-With, the defusable swipe-to-resolve open, the bubble-morph animation requirement, and the appearance/behavior customization surface.

### Modified Capabilities
- `launcher-overlay`: add the Files band's overlay behavior (the layer that already owns the Clipboard master-detail and AI-canvas requirements) — the icon-rail + current-list + live-preview column layout, horizontal-depth / vertical-highlight navigation, type-to-filter search focus, the swipe-to-resolve defusable open (down = open, horizontal = discard) with the relative +1-finger Open-With, and the bubble-morph presentation law.
- `gesture-recognition`: add a sustained **files-drill modal sub-state** that bypasses the finger-count latch (mirroring the existing AI canvas-resolution mode) and emits depth / highlight / focus-search / open / open-with / discard intents — including **relative +1-finger** detection (a finger added vs. the relaxed baseline, not an absolute count) and mandatory contact-count re-baselining so a leaving finger fires no phantom step.
- `configuration-hub`: add a **Files** page to the Hub sidebar hosting the roots editor and the appearance + behavior controls.

## Impact

- **New files:** `FilesBandBuilder` (synthetic band factory, own sentinel id), `FilesBandView` (the column-navigator overlay view), `FilesNavigationModel` (the path/column state machine — pure, testable), `Overlay/BubbleMorph.swift` (reusable scale-from-droplet modifier — the app's first spring), and a `FileOpenService` (on-demand directory listing, Quick Look, `urlsForApplications(toOpen:)` enumeration, and the defusable open).
- **Surgical edits:** `LaunchItem` (new ephemeral `.fileEntry` kind + every exhaustive `switch` site), `LauncherModel` (`filesBandIndex` / `currentBandIsFiles` + column navigation), `LauncherView` (a render branch before the grid fallback), `LauncherOverlayController` (Files panel sizing, the held-state lifecycle, the animated teardown), `GestureRecognizer` (the drill-in sub-state + new delegate methods with default no-ops), `AppCoordinator` (injection in `launcherDidActivate` + flag wiring), `AppSettings` (the opt-in + Files tunables), and the Hub (`BandsCanvas` / a new page).
- **APIs / dependencies:** adds `QuickLookThumbnailing` (by promoting the existing private `FilePreview`) and `NSWorkspace.urlsForApplications(toOpen:)` / `urlForApplication(toOpen:)`. No new entitlement, no new permission, no native-gesture relocation. The MLX / `GemmaRuntime` split is untouched.
- **Verification:** all Core logic (the navigation state machine, +1-finger Open-With detection, the search clamp-overflow rule, the band builder, and the open/Open-With service against a stubbed workspace) verified by `swift build` / `swift test`; the existing 614 tests stay green.
- **Errors** inherit the established taxonomy: filesystem / `NSWorkspace` failures are mapped at the layer boundary and surface as a bounded, non-blocking `.failed` state with a clean headline — never a silent, false "opened."
