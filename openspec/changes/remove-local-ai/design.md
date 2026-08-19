# Design — remove-local-ai

## D1 — Snapshot before the cut

The full-featured app is preserved twice before anything is deleted: the **`v1` branch** (exact source) and the **`v1.0.0` tag** (triggers the release pipeline → a notarized DMG on GitHub Releases). Nothing in this change is unrecoverable.

## D2 — Favorites migration: lossy decode, not a throwing one

`FavoritesStore` loads the record with `try? decode` and **reseeds on failure**. Removing the `.aiCommand` case from `LaunchItemKind` would make every stored record containing one fail to decode — and the reseed would silently wipe the user's real bands on first launch. So:

- `ContextBand` gains a custom `init(from:)` that decodes items through a `FailableItem` wrapper (`try? LaunchItem(from:)`): an undecodable **item** is dropped; the **band** (and record) survive. This also future-proofs any later kind retirement.
- `Favorites.currentSchemaVersion` bumps to **3**. The v3 step in `FavoritesStore.migrate` removes the seeded "AI" band — recognized by the retired `AIBand.bandID` sentinel UUID, hardcoded in the migration — but only when it is empty after the item drop (a renamed/repurposed band with surviving items belongs to the user and is kept). `homeBandID` is re-pointed if it referenced the removed band.
- `.fileEntry` was never persisted (synthetic band), so it needs no migration; `.action(.speakLastResponse)` items fall out via the same lossy decode.

## D3 — GestureBindings shrink is decode-safe by construction

The stored bindings blob is JSON; `JSONDecoder` ignores unknown keys. Removing the `canvas` and `filesDrill` properties means older blobs (which still carry those keys) decode into just the `switcher` binding — no version bump, no custom decoder. A corrupted blob already fell back to defaults.

## D4 — What deliberately survives

- **`ScrollEventTap` + the odometer + edge auto-repeat**: untouched; only the canvas/Files special cases inside them were removed.
- **Dock previews, ⌘-Tab, window groups, minimize-all, keyboard language, device link**: untouched keepers. (Device link is the *remote-sync* feature — a candidate for a later cleanup, explicitly out of scope here.)
- **The error-handling convention** (one taxonomy per domain, mapped at the boundary, bounded + non-blocking surfaces) originated in the AI work and remains the house style — restated in CLAUDE.md without the AI examples.
- **`xcodebuild` in `build-app.sh`**: kept. MLX was the original reason, but the script's packaging/signing flow is proven; `swift build` remains the agent verify loop. The generic `*.bundle` copy loop stays (harmless no-op today).
- **The `openspec/changes/archive/`**: all `ai-*`/`files-*` history stays — it documents decisions this repo may want to revisit.

## D5 — Danger zone loses the AI-models card

`DangerZoneSelection.aiModels` is gone; `.appData` now removes the whole Application Support root (there is no `models/` survivor split to preserve). Already-downloaded weights on a user's disk are not auto-deleted by this change — deleting user data as a side effect of an update would be wrong; the release notes point at the folder instead.
