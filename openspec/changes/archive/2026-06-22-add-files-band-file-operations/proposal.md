## Why

The action menu can **Copy** and **Paste-into** (`add-files-band-actions`), but it can't **Cut** (move) or **Delete** — the two operations a file manager needs most. The band sits one flick from wherever you were, so "move this file into that folder" and "trash this" are exactly the moves it should own. The just-shipped **dwell-to-arm** (`add-files-band-dwell-arm`) makes that safe: every menu-row commit now requires a deliberate rest-to-arm + haptic before the lift fires, so a destructive action can't go off on a stray scrub-and-lift. And the action menu is currently a **fixed 280-wide / 360-tall box**, which looks oversized around a short "Copy · Cut · Delete" list — it should fit its content.

## What Changes

- **Cut = move on the next Paste (Finder ⌘X).** A new **Cut** menu action marks the highlighted entry and writes its `fileURL` to the pasteboard (recording the pasteboard's change-count). The existing **Paste** becomes **dual-mode**: when the live pasteboard is still that cut (change-count unchanged), Paste **moves** the entry into the target folder; otherwise it **copies** as today. Both keep the existing **keep-both** rename on conflict (never overwrite). **Copy** still copies; an intervening Copy (or any external pasteboard write) **supersedes** the cut, so Paste falls back to copy. The move clears the mark.
- **Delete = move to Trash (recoverable).** A new **Delete** menu action moves the entry to the **Trash** via `FileManager.trashItem` — never a permanent `removeItem`, so it is always recoverable from Finder. A failed trash surfaces as the existing **bounded, non-blocking** failure row (a new `FileActionError.trashFailed`), never an alert, never raw error text in the headline.
- **Cut and Delete default for files AND folders.** Both are added to the default file and folder menus (Copy as path · Copy · **Cut** · Paste · Open in ▸ · **Delete**; folders also keep ‹terminals›). They remain **removable/reorderable per-type** from the Hub Files page (the catalog editor is data-driven, so they appear there automatically). Delete sits **last** (set apart from the everyday actions); Cut pairs with Copy.
- **The action menu fits its content.** Its width is **measured from the widest row label** (bounded to a sensible min/max) instead of a fixed 280, and its height already tracks its rows — so a short menu is compact and a long label still truncates within the cap.
- **Scope widens — and is re-stated honestly.** The `files-band` "non-destructive" scope grows from the single copy-in to **copy-in, move-in (Cut→Paste), and trash (Delete)** — all **recoverable / non-overwriting**: still **no permanent delete**, **no overwrite** (keep-both throughout), and **no rename or tag**. Local-only is unchanged.
- **No new permission, no gesture relocation, no new haptic.** Cut/Delete are menu rows resolved by the existing dwell-armed lift; Trash and move are `FileManager` calls (no new entitlement). The dwell-arm is the deliberate-confirm — no separate confirmation dialog (the band stays pure-trackpad, no keypress).

## Capabilities

### Modified Capabilities

- `files-band`: the **Local-only, non-destructive scope** requirement is re-stated — the band's mutations now include **move-in (Cut→Paste)** and **trash (Delete)** in addition to the copy-in, bounded to **recoverable, non-overwriting** operations (no permanent delete, no overwrite, no rename/tag); local-only unchanged.
- `files-action-menu`: the catalog gains **Cut** and **Delete** (default for both types); **Paste** is specified as **dual-mode** (move after Cut, copy after Copy, keep-both either way); the menu **sizes to its content**.

## Impact

- **Code (MLX-free Core + app):**
  - **Catalog/model (`Files/FilesActionMenu.swift`):** add `FilesMenuAction.cut` + `.delete`; add both to `defaultFileItems` / `defaultFolderItems` (Delete last) and `defaultCatalog`. Pure → existing `FilesActionMenuTests` extended.
  - **Effects (`App/AppCoordinator.swift`):** a `pendingCut` marker (`sources` + pasteboard `changeCount`); `performPasteInto` becomes dual-mode (`moveItem` when the cut still matches, else `copyItem`, keep-both both ways, clears the mark on move); a `performDelete` via `FileManager.trashItem`; `performMenuAction` gains `.cut` / `.delete`.
  - **Errors (`Files/FileWorkspace.swift`):** new `FileActionError.trashFailed(name:details:)` + its clean headline + opt-in details (mapped at the boundary).
  - **View (`Overlay/FilesBandView.swift`):** `.cut` / `.delete` cases in `menuRowLabel` / `menuRowGlyph`; the action menu's width measured from its content (bounded) instead of fixed `pickerWidth`.
  - **Hub:** **no change** — the catalog editor iterates `FilesMenuAction.allCases` + reuses `menuRowLabel`/`menuRowGlyph`, so Cut/Delete appear automatically; un-customized users get the new defaults (the persisted menu falls back to `Defaults` until customized).
- **Reuse, not rebuild:** the dwell-armed lift gate, the existing keep-both resolver (`FilesPasteName`), the bounded failure-row + Retry, the pasteboard write path, and the data-driven Hub editor.
- **Depends on `add-files-band-actions`** (the action menu + Paste-into this extends) and composes with `add-files-band-dwell-arm` (the commit gate). The `files-band` scope delta MODIFIES a requirement that exists in main; the `files-action-menu` additions are ADDED requirements — both validate independently and this change archives **after** `add-files-band-actions`.
- **Out of scope:** permanent delete (`removeItem`); overwrite on conflict (keep-both stays); rename/tag/duplicate as distinct actions; non-file pasteboard sources for move/copy (file URLs only); a confirmation dialog (the dwell-arm is the confirm); network/iCloud locations.
