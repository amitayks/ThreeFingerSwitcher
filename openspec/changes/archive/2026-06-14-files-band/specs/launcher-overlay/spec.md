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

In the Files band, **horizontal** travel SHALL be the **depth** axis and **vertical** travel SHALL move the **highlight** within the current folder: horizontal in the descend direction enters the highlighted folder (collapsing the prior current list into its ancestor icon and budding the child list in), horizontal in the ascend direction returns one level (the deepest ancestor icon blooming back into the full current list), and vertical steps the highlight up/down the current list. These SHALL honor the **same direction-inversion settings** as the rest of the launcher. **Both axes SHALL use the launcher's odometer step distance (`launcherStepDistance`) — accumulated travel with carry — and SHALL auto-repeat at the trackpad edge** — depth has full parity with the launcher's item axis, so holding a contact at the horizontal edge auto-drills (descends/ascends) through the tree, just as holding at the vertical edge auto-scrolls the list. *(This supersedes the earlier rule that depth was a deliberate, non-auto-repeating step; the snappier, edge-accelerated depth was chosen deliberately.)*

#### Scenario: Horizontal descends into the highlighted folder
- **WHEN** a folder is highlighted and the user travels horizontally in the descend direction past the step distance
- **THEN** the navigator descends: the prior current list collapses into an ancestor icon and the folder's contents bud in as the new current list

#### Scenario: Horizontal ascends one level
- **WHEN** the user travels horizontally in the ascend direction
- **THEN** the deepest ancestor icon blooms back into the current list and the prior current list recedes

#### Scenario: Vertical moves the highlight
- **WHEN** the user travels vertically in the current list
- **THEN** the highlight steps to the adjacent entry

#### Scenario: Held horizontal edge auto-drills through the tree
- **WHEN** the user holds the controlling contact at the horizontal border in the Files band
- **THEN** depth auto-repeats with border acceleration (descending/ascending through the tree), exactly as holding at the vertical border auto-scrolls the list

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

### Requirement: Files band is pure-trackpad (no type-to-filter search)

The Files band SHALL be navigated **entirely by trackpad** with **no keyboard input** of any kind: there SHALL be no type-to-filter search field, and the overlay panel SHALL never become key/main for the Files band. An **up** step at the top of the current list SHALL simply **clamp** (the highlight stays on the top row) — it SHALL NOT focus a search field or any other keyboard surface. This keeps the band consistent with the app's "pure trackpad, no keypresses" rule with no exception.

#### Scenario: Up at the top of the list clamps
- **WHEN** the highlight is at the top entry and the user steps up again
- **THEN** the highlight stays on the top row and no search field or keyboard focus is engaged

#### Scenario: The Files navigator takes no keyboard input
- **WHEN** the Files band is open at any depth
- **THEN** every interaction is a trackpad intent and the overlay panel does not become key/main

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
