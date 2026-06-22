## Context

The action menu already has the seams: a catalog enum (`FilesMenuAction`), a data-driven Hub editor, a bounded failure row, the keep-both rename resolver (`FilesPasteName`), and — as of `add-files-band-dwell-arm` — a dwell-armed lift gating every row commit. This change adds two catalog actions and makes Paste dual-mode; nothing structural is new.

- **Paste-into today is a one-way copy.** `AppCoordinator.performPasteInto` reads the pasteboard's file URLs and `FileManager.copyItem`s each into the target (a folder, or a file's containing folder), keep-both via `FilesPasteName.uniqueName`. Cut reuses this path verbatim, swapping `copyItem` for `moveItem` when the paste is fulfilling a cut.
- **The pasteboard has no native file "cut" flag.** macOS Finder's ⌘X is private. The portable, robust rule: record the pasteboard `changeCount` at cut time; a later Paste is a move **iff** `NSPasteboard.general.changeCount` still equals it (the pasteboard hasn't been rewritten since). Any Copy / external write bumps the count → the cut is superseded → Paste copies. This needs no entitlement and no cross-app cooperation.
- **Delete is just Trash.** `FileManager.trashItem` is sandbox-safe for user-chosen paths (the band lists local roots the user configured) and recoverable — so "delete" never means permanent loss. Errors map at the boundary into a new `FileActionError.trashFailed`.
- **The Hub editor is data-driven.** It lists `FilesMenuAction.allCases` and renders each via `FilesBandView.menuRowLabel`/`menuRowGlyph`. New catalog cases appear automatically; the persisted `filesActionMenu` falls back to `Defaults` until the user customizes, so un-customized users get the new defaults for free.

## Goals / Non-Goals

**Goals:**
- Cut → move-on-Paste (dual-mode Paste), keep-both on conflict, supersede-on-rewrite; Delete → recoverable Trash; both default for files and folders, reorderable/removable in the Hub.
- Every destructive commit rides the existing dwell-armed lift (the deliberate confirm) and the bounded failure-row — no alert, no raw error text, no permanent loss.
- The action menu fits its content (width measured from the widest label, bounded).
- Re-state the `files-band` scope honestly: recoverable file operations, never irreversible.

**Non-Goals:**
- Permanent delete (`removeItem`), overwrite-on-conflict (keep-both stays), rename/tag/duplicate as their own actions.
- A confirmation dialog or any keypress (the dwell-arm is the confirm; the band stays pure-trackpad).
- Non-file pasteboard sources for move/copy (file URLs only, unchanged).
- New permission, new haptic, gesture relocation.

## Decisions

**1. Cut is a pasteboard write + a change-count mark; Paste is dual-mode.**
`Cut` writes the entry's `fileURL` to the pasteboard (exactly like `Copy`) and records `pendingCut = (sources, NSPasteboard.general.changeCount)` (the count **after** the write). `performPasteInto` computes `isMove = pendingCut?.changeCount == NSPasteboard.general.changeCount`; when true it `moveItem`s (keep-both target name) and clears `pendingCut`; otherwise it `copyItem`s as before. So Copy→Paste copies, Cut→Paste moves, and a Copy (or any pasteboard rewrite) between Cut and Paste makes the count diverge → Paste copies. The mark is coordinator state, so a Cut persists across launcher sessions until consumed or superseded — matching Finder.
  *Alternative considered (a custom pasteboard type / UTI flag):* unnecessary — the change-count rule is simpler, needs no declared type, and degrades safely (an external paste just copies).

**2. Delete is Trash, never permanent.**
`performDelete` calls `FileManager.trashItem(at:resultingItemURL:)`. Success dismisses the navigator (consistent with the other committing actions — Copy/Paste/Reveal all `hide()`); the trashed entry is simply gone on the next open (no in-place list surgery needed). Failure maps to `FileActionError.trashFailed(name:details:)` → the bounded row + Retry. **No** `removeItem` path ships.

**3. Both are dwell-armed menu commits — the confirm is the arm, not a dialog.**
Cut/Delete are ordinary `FilesMenuRow.action` rows committed by the dwell-armed lift (`add-files-band-dwell-arm`): the row must rest-to-arm (charge ring + haptic) before the lift fires it. That deliberate gesture **is** the confirmation; adding a modal confirm would break the pure-trackpad, no-keypress invariant and the non-activating overlay. Delete is ordered **last** in the default menus so reaching it means scrubbing past the benign actions — a mild extra deliberateness.

**4. Defaults change; persistence migrates for free.**
`defaultFileItems` → `[copyAsPath, copy, cut, pasteInto, openIn, delete]`; `defaultFolderItems` → `[copyAsPath, copy, cut, pasteInto, openInTerminals, openIn, delete]`. `cut`/`delete` join `defaultCatalog`. Because `AppSettings.filesActionMenu` loads `?? Defaults.filesActionMenu` and only persists on customize, un-customized users pick up the new defaults; customized users keep their lists and can add Cut/Delete from the Hub; reset restores the new defaults.

**5. The action menu sizes to its content.**
Replace the fixed `.frame(width: pickerWidth)` on the action-menu panel with a width **measured** from its rows: `max` over each row label's rendered width (`NSString.size(withAttributes:)` at the real 13pt font) plus the glyph + chevron + padding, and the header (the entry name), clamped to a sensible `[min, max]`. Height already tracks the rows (`maxHeight` is only a safety cap). The single-sliding highlight keeps a definite width (so no fixedSize/flexible-pill ambiguity). Scoped to the action menu (the ask); the Open-With grid keeps its fixed width.

## Risks / Trade-offs

- **Cut→Paste is the band's first MOVE** (relocates the source). Bounded: keep-both target name (never overwrites), file-URLs only, change-count-gated (an external paste can't accidentally trigger a move — it copies), errors boundary-mapped. Recoverable in the sense that nothing is destroyed; the source is relocated, not lost.
- **Delete removes from the current view** — mitigated by Trash (recoverable) + the dwell-arm confirm + Delete-ordered-last. No permanent-delete path exists to mis-fire.
- **A stale `pendingCut` across sessions** could move on a much-later Paste — but only while the pasteboard is *still that exact cut* (any copy since supersedes it), which is precisely Finder's behavior; acceptable and expected.
- **Scope widening** to move + trash is real — re-stated in the spec as bounded **recoverable** operations (no permanent delete, no overwrite, no rename/tag), so "non-destructive of data" still holds.
- **Menu-width measurement uses font metrics** (view-layer, not pure) — kept to a clamped heuristic so a pathological label can't overflow or collapse the panel.

## Open Questions (tuning, not design)

- The menu width **clamp bounds** (min/max) and the per-row padding constants — pick sensible defaults, confirm in run-verify that "Copy" isn't cramped and "Open in Visual Studio Code" truncates cleanly.
- Whether **Delete** should additionally keep the navigator open (delete-several-in-a-row) rather than dismiss — deferred; it dismisses like every other committing action for now (revisit in run-verify if it feels wrong).
