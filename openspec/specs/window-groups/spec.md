# window-groups Specification

## Purpose
Snap-to-bind window groups: a window drag ending edge-flush against another current-Space window binds the two into a runtime group. The switcher renders a group as a fused cluster (members at their real relative arrangement, individually highlightable) and a commit raises the whole group with the selected member focused. Opt-in, runtime-only, no new permission.

## Requirements
### Requirement: Opt-in gate with no side effects when off

Window groups SHALL be governed by an opt-in setting (default OFF). While off, the system SHALL install no mouse monitors for snap detection, SHALL pass no groups to the switcher, and SHALL commit selections exactly as without this capability. Turning the setting off SHALL clear any existing groups (so re-enabling never resurrects stale state). The capability SHALL require no new permission (passive global mouse monitors and existing window enumeration only), no re-login, and no gesture relocation.

#### Scenario: Off means byte-identical behavior

- **WHEN** the setting is off
- **THEN** no snap detection runs, the switcher renders and commits exactly as before this capability existed

#### Scenario: Toggling off clears groups

- **WHEN** groups exist and the user turns the setting off, then later back on
- **THEN** no prior group survives the off period

### Requirement: A drag ending edge-flush binds the dragged window into a group

When a window drag (or resize) ends with the window's edge flush against another current-Space window's facing edge — gap at most a small tolerance that covers both a zero gap and the system "tiled windows have margins" gap, AND a minimum shared extent along the touching edge (a corner touch SHALL NOT bind) — the system SHALL bind the dragged window and the touched window(s) into one group. Binding SHALL merge groups transitively (binding A to B when B is grouped with C yields one group {A, B, C}). Only the **dragged** window's contacts bind: two windows that merely happen to rest adjacent without a drag ending on the contact SHALL NOT be bound. Because the snap animates the window into place after release, the adjacency evaluation SHALL read the settled frame (a short settle delay), not the mid-flight one.

#### Scenario: Snap creates a group

- **WHEN** the user drags window A until it snaps flush against window B's edge and releases
- **THEN** A and B form a group

#### Scenario: Margin gap still binds

- **WHEN** the system tiling margin leaves a small uniform gap between the snapped windows
- **THEN** the pair is still bound (the tolerance covers the margin)

#### Scenario: Corner touch does not bind

- **WHEN** a drag ends with two windows touching only near a corner (shared edge extent below the minimum)
- **THEN** no group is created

#### Scenario: Binding merges existing groups

- **WHEN** window A is dragged flush against window B, and B is already grouped with C
- **THEN** A, B, and C are one group

### Requirement: Groups mean physical attachment and dissolve when it ends

Group membership SHALL end for a member that is dragged (or resized) away from all of its group-mates, and for a member that is closed, minimized, or moved to another Space — validated against live window state at every consumption point (switcher snapshot assembly and commit) so a stale member can neither render nor be raised. Contact SHALL be judged by TWO tests, selected by intent: a **drag of a member is an explicit re-arrangement of that member**, so at drag-end its bonds re-evaluate STRICTLY — it keeps/creates bonds only to what it sits flush against, and ending with a gap OR on top of a mate both break the old bond (on a crowded screen a dragged-out window almost always lands overlapping some member; a loose test here would make breaking a group nearly impossible). **Passive geometry changes** (resizes — attributed or not — and moves no drag expressed intent about) use the looser *stay-bound* test: the bond persists while the windows touch **or overlap** (more than a corner brush); only a real gap detaches. A break SHALL take effect immediately at the first settled evaluation (never deferred behind a re-check that could be cancelled). A group reduced below two members SHALL dissolve. Groups SHALL be runtime-only (never persisted across app restarts).

#### Scenario: Dragging apart unbinds

- **WHEN** a member of a group is dragged away so it is no longer edge-adjacent to any group-mate
- **THEN** that member leaves the group (and the group dissolves if fewer than two members remain)

#### Scenario: Overlap from passive geometry keeps the bond

- **WHEN** a group member comes to overlap a group-mate WITHOUT being dragged there (resized over it, including an unattributable border-grab resize, or the mate grew over it)
- **THEN** the bond persists — overlap is physical contact, not detachment — and the group survives every geometry re-check and consumption-point validation; overlap alone SHALL NOT create a new bond (binding still requires the flush snap)

#### Scenario: Dragging a member onto a mate breaks the bond

- **WHEN** a group member is DRAGGED and the drag ends on top of a group-mate rather than flush against it
- **THEN** the member leaves the group immediately (the drag expressed intent about that member; strict flush is the only drag-end contact that keeps a bond)

#### Scenario: Closing or minimizing a member removes it

- **WHEN** a group member is closed or minimized
- **THEN** the next switcher presentation and any commit treat the group without that member (dissolving it below two members)

#### Scenario: Dragging a member onto a new contact rebinds it

- **WHEN** a member of group {A, B} is dragged away from B and its drag ends flush against window C
- **THEN** A leaves {A, B} and forms {A, C}

#### Scenario: Resizing away unbinds, even when the input cannot be attributed

- **WHEN** a group member's border is resized so it no longer touches any group-mate — including a border grab starting in the grab zone outside the window's frame (which cannot be credited to the right window) or a keyboard/AX-driven resize the mouse monitor never observes
- **THEN** detachment is judged GEOMETRICALLY (members that no longer touch have detached): the member leaves the group no later than the next geometry re-check (any mouse-up while groups exist) or consumption point (switcher presentation, commit), splitting a chain into its still-touching components

### Requirement: Committing a grouped window raises the whole group with the selected member focused

When the committed switcher selection (trackpad lift or ⌘-Tab release — the shared commit path) belongs to a validated group, the system SHALL raise **every** group member above other windows, with the **selected** member raised last, topmost, and receiving keyboard focus. Group mates SHALL be fronted via a light path (no focus-history promotion, no focus watchdog, with the established Stage-Manager fallback); only the selected member SHALL go through the hardened focused raise. A commit of an ungrouped window SHALL behave exactly as before.

#### Scenario: Both windows pop to front, selected focused

- **WHEN** the user commits a window that is grouped with one other window
- **THEN** both windows come to the front, and the committed window is topmost with keyboard focus

#### Scenario: ⌘-Tab inherits the group commit

- **WHEN** the user releases ⌘ over a grouped window in the ⌘-Tab switcher
- **THEN** the same group raise occurs (all members fronted, the selected one focused)

#### Scenario: Ungrouped commit unchanged

- **WHEN** the committed window belongs to no group
- **THEN** the raise behaves exactly as without this capability
