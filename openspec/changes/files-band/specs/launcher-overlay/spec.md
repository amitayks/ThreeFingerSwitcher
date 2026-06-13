## ADDED Requirements

### Requirement: Files band column-navigator layout

The Files band SHALL render as a **column navigator** rather than the icon grid: a thin **icon rail of ancestor folders** on the left (one collapsed icon per ancestor, the deepest nearest the current column), a single **current-folder list** (the full vertical list of the current folder's entries, each with a type glyph), and a single **live preview** pane on the right. At any depth exactly one current-folder list and one preview are shown at full size; all ancestors are collapsed to the icon rail, so the visible width is **bounded regardless of navigation depth**. The overlay SHALL be sized to show several entries and a sizeable preview at once, and SHALL be sized to its **final frame** for a given depth (not re-stretched mid-animation).

#### Scenario: Layout is rail + current list + preview
- **WHEN** the Files band is shown at any depth
- **THEN** ancestors appear as a left icon rail, the current folder is a full vertical list, and the highlighted entry has a live preview on the right

#### Scenario: Visible width stays bounded with depth
- **WHEN** the user descends many levels
- **THEN** only one current list and one preview are shown at full size; deeper ancestors remain collapsed icons

### Requirement: Files band depth and highlight navigation

In the Files band, **horizontal** travel SHALL be the **depth** axis and **vertical** travel SHALL move the **highlight** within the current folder: horizontal in the descend direction enters the highlighted folder (collapsing the prior current list into its ancestor icon and budding the child list in), horizontal in the ascend direction returns one level (the deepest ancestor icon blooming back into the full current list), and vertical steps the highlight up/down the current list. These SHALL honor the **same direction-inversion settings** as the rest of the launcher. Horizontal depth steps SHALL require the same deliberate per-step travel as item-stepping and SHALL **NOT auto-repeat at the horizontal edges** (so a held edge cannot run away descending/ascending through the tree); vertical highlight stepping SHALL auto-repeat with acceleration like other bands.

#### Scenario: Horizontal descends into the highlighted folder
- **WHEN** a folder is highlighted and the user travels horizontally in the descend direction past the step distance
- **THEN** the navigator descends: the prior current list collapses into an ancestor icon and the folder's contents bud in as the new current list

#### Scenario: Horizontal ascends one level
- **WHEN** the user travels horizontally in the ascend direction
- **THEN** the deepest ancestor icon blooms back into the current list and the prior current list recedes

#### Scenario: Vertical moves the highlight
- **WHEN** the user travels vertically in the current list
- **THEN** the highlight steps to the adjacent entry

#### Scenario: Held horizontal edge does not run away through the tree
- **WHEN** the user holds the controlling contact at a horizontal edge in the Files band
- **THEN** depth does not auto-repeat (no runaway descent/ascent); only a fresh deliberate horizontal excursion changes depth

### Requirement: Files band live preview

The Files band's preview pane SHALL show the **actual content of the highlighted entry**: a Quick Look-class content preview for a **file** (not merely its icon — with the file/app icon as a fallback when no preview is available), and a **peek of its contents** for a **folder**. The preview SHALL update as the highlight moves and SHALL load **without blocking navigation**. The preview pane SHALL NOT be a separately focusable/navigable pane (there is no horizontal crossing into it — horizontal is the depth axis).

#### Scenario: A highlighted file previews its content
- **WHEN** the highlight rests on a file
- **THEN** the preview shows a content preview of that file (with the file/app icon as a fallback)

#### Scenario: A highlighted folder previews a peek of its contents
- **WHEN** the highlight rests on a folder
- **THEN** the preview shows a peek of that folder's contents

#### Scenario: The preview is not separately navigable
- **WHEN** the user travels horizontally with a file highlighted
- **THEN** horizontal is interpreted as depth (no crossing into the preview pane)

### Requirement: Files band type-to-filter search

From the top of the current list, a further **up** step SHALL move focus to a **search field** for the current folder (a clamp-overflow: the recognizer keeps emitting up-steps; the controller interprets an up-step while already at the top as focusing search). While the search field is focused the user MAY **type with the keyboard** to **filter the current folder's entries** live; this typed search is the **single, scoped exception** to the app's no-keypresses rule. A downward step from the focused search field SHALL return focus to the (filtered) list. Clearing the query SHALL restore the full list.

#### Scenario: Up from the top focuses search
- **WHEN** the highlight is at the top entry and the user steps up again
- **THEN** focus moves to the search field for the current folder

#### Scenario: Typing filters the current folder live
- **WHEN** the search field is focused and the user types a query
- **THEN** the current list filters to matching entries as the user types

#### Scenario: Stepping down returns to the list
- **WHEN** the search field is focused and the user steps down
- **THEN** focus returns to the (filtered) current list

### Requirement: Files band resolution — open, Open-With, discard

Resolution of a Files-band selection SHALL be **lift-to-open with a defusable commit** (the navigator's reach-in-and-open intent — *not* the AI canvas's review-then-apply). **Lifting** on a highlighted entry SHALL **open** it — a file in its default application, a folder as a Finder window — on the current Space; the open SHALL be **defusable** for a brief window so a discard issued before it fires opens nothing. Adding a finger before the resolving lift — a **relative +1 finger** versus the current relaxed contact baseline — SHALL instead arm **Open-With**, so the lift presents the **relevant-apps picker** for the highlighted file, which the user navigates (vertical) and lifts to choose; choosing opens the file with that app. A fresh deliberate **four-finger horizontal swipe-away** SHALL **discard** — defusing any pending open and writing nothing — and SHALL **never terminate an already-running application**. Resolution SHALL be **one-shot**: once opened or discarded, a stray re-lift is a no-op. The captured front app SHALL remain frontmost throughout.

#### Scenario: Lift opens the highlighted entry
- **WHEN** the user lifts on a highlighted file (or folder)
- **THEN** it opens in its default app (or as a Finder window) on the current Space

#### Scenario: Four-finger swipe-away discards before it opens
- **WHEN** the user makes a four-finger horizontal swipe-away instead of lifting (or within the defuse window)
- **THEN** nothing opens, any pending open is defused, and no running application is terminated

#### Scenario: Plus-one finger opens the Open-With picker
- **WHEN** the user adds a finger (one more than the current relaxed baseline) and lifts on a file
- **THEN** the relevant-apps picker opens, which the user navigates and lifts to choose the opening app

#### Scenario: Resolution is one-shot
- **WHEN** the selection has already been opened or discarded
- **THEN** a subsequent stray re-lift does nothing

### Requirement: Bubble-morph presentation in the Files band

Every element that appears in the Files band — each column/list, each row's content, the preview, the ancestor icons, and the Open-With menu — SHALL **animate into presence** rather than appear abruptly: it SHALL scale up from a near-zero "droplet" while fading in, on a **soft spring**, and SHALL recede the same way on leave. Descending SHALL animate the current list **collapsing into its ancestor icon** while the child list **buds in**; ascending SHALL animate the ancestor icon **blooming back** into the full list. The single moving selection highlight SHALL remain a **continuous sliding element** (it SHALL NOT be re-created per row, to avoid scrub strobing); only entry **content** and **structural** changes use the morph. No element SHALL "pop" to full size instantly. This presentation SHALL introduce **no new haptics** beyond the existing arm tick, and SHALL respect the non-activating overlay (display-only animation; the overlay never becomes key).

#### Scenario: Nothing pops in
- **WHEN** any column, row content, preview, ancestor icon, or menu appears
- **THEN** it scales-and-fades up from a droplet on a soft spring rather than appearing at full size instantly

#### Scenario: Descend collapses the current list into its icon
- **WHEN** the user descends into a folder
- **THEN** the prior current list animates into its ancestor icon while the child list buds in

#### Scenario: Ascend blooms the icon back
- **WHEN** the user ascends
- **THEN** the deepest ancestor icon animates back into a full current list while the prior list recedes

#### Scenario: The moving highlight does not strobe
- **WHEN** the user scrubs quickly through the current list
- **THEN** the selection highlight slides continuously (it is not re-created per row) and does not flicker
