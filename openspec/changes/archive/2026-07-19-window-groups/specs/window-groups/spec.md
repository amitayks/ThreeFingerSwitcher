# window-groups

Snap-to-bind window groups: windows snapped edge-to-edge become a group that the switcher presents and raises as a unit, with individual member selection. Opt-in, runtime-only, no new permission.

## ADDED Requirements

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

Group membership SHALL end for a member that is dragged (or resized) away from all of its group-mates, and for a member that is closed, minimized, or moved to another Space — validated against live window state at every consumption point (switcher snapshot assembly and commit) so a stale member can neither render nor be raised. A group reduced below two members SHALL dissolve. Groups SHALL be runtime-only (never persisted across app restarts).

#### Scenario: Dragging apart unbinds

- **WHEN** a member of a group is dragged away so it is no longer edge-adjacent to any group-mate
- **THEN** that member leaves the group (and the group dissolves if fewer than two members remain)

#### Scenario: Closing or minimizing a member removes it

- **WHEN** a group member is closed or minimized
- **THEN** the next switcher presentation and any commit treat the group without that member (dissolving it below two members)

#### Scenario: Dragging a member onto a new contact rebinds it

- **WHEN** a member of group {A, B} is dragged away from B and its drag ends flush against window C
- **THEN** A leaves {A, B} and forms {A, C}

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
