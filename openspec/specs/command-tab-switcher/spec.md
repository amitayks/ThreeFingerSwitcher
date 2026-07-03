# command-tab-switcher Specification

## Purpose
TBD - created by archiving change command-tab-switcher. Update Purpose after archive.
## Requirements
### Requirement: Opt-in gate leaves native ⌘-Tab untouched when off

The ⌘-Tab keyboard driver SHALL be governed by an opt-in setting that defaults to OFF. When OFF, the app SHALL NOT intercept ⌘-Tab and the native macOS application switcher SHALL behave exactly as it would without the app. Because interception is a live keyboard event tap (not a gesture relocation), toggling the setting SHALL take effect immediately with no re-login.

#### Scenario: Native switcher works when the feature is off

- **WHEN** the opt-in is off and the user presses ⌘-Tab
- **THEN** the native macOS application switcher appears and behaves normally
- **AND** the app's window switcher does not open

#### Scenario: Toggling off restores native ⌘-Tab immediately

- **WHEN** the feature was on and the user turns the opt-in off
- **THEN** the keyboard interception stops without a re-login
- **AND** the next ⌘-Tab shows the native application switcher

### Requirement: Intercept ⌘-Tab and suppress the native application switcher when enabled

When the opt-in is ON and Input Monitoring is granted, the app SHALL install a keyboard event tap that, while the ⌘ modifier is held, consumes the `Tab` key (and Shift+Tab) so the native application-switcher HUD never appears. The tap SHALL pass through every other event unmodified — ⌘ combined with any non-`Tab` key, and a bare `Tab` with no ⌘ — so no other shortcut is affected.

#### Scenario: ⌘-Tab is consumed and the native HUD does not appear

- **WHEN** the feature is on and the user holds ⌘ and presses Tab
- **THEN** the native application-switcher HUD does not appear
- **AND** the app's window switcher opens instead

#### Scenario: Other ⌘ shortcuts pass through

- **WHEN** the feature is on and the user presses a ⌘ combination whose key is not Tab (e.g. ⌘-Q, ⌘-W, ⌘-Space)
- **THEN** the event is delivered unmodified to the focused application

#### Scenario: A bare Tab passes through

- **WHEN** the feature is on and the user presses Tab without ⌘ held
- **THEN** the event is delivered unmodified to the focused application

### Requirement: The first Tab opens the switcher and advances immediately

While ⌘ is held, the FIRST Tab SHALL open the existing window switcher overlay (reusing its overlay, model, thumbnails, and live preview) AND immediately step the selection one window in the Tab's direction — ⌘-Tab to the next window, ⌘-Shift-Tab to the previous — so a quick press-and-release lands on the adjacent window like the native switcher, rather than merely highlighting the current one. Merely holding ⌘ SHALL NOT open the overlay; only a Tab opens it. The driver SHALL be inert (open nothing) while onboarding owns the stage (the wizard or a Hub teaching demo).

#### Scenario: First ⌘-Tab opens and advances to the next window

- **WHEN** the user holds ⌘ and presses Tab for the first time in the session
- **THEN** the window switcher overlay opens with the highlight already moved one window forward (the next window), not resting on the current one

#### Scenario: First ⌘-Shift-Tab opens and steps to the previous window

- **WHEN** the user holds ⌘ and presses Shift+Tab for the first time in the session
- **THEN** the overlay opens with the highlight already moved one window backward (the previous window)

#### Scenario: Holding ⌘ alone opens nothing

- **WHEN** the user holds ⌘ but presses no Tab, then releases ⌘
- **THEN** the window switcher never opens and nothing is committed

#### Scenario: Inert while onboarding owns the stage

- **WHEN** the first-run wizard or a Hub switcher demo owns the stage and the user presses ⌘-Tab
- **THEN** the keyboard driver opens nothing (the onboarding stage is unaffected)

### Requirement: Tab steps the selection forward linearly across Spaces

With the overlay open and ⌘ held, each Tab SHALL advance the selection forward by one window along the overlay's own flat order — the Space-rows in Mission-Control order, each row's windows in snapshot order. Advancing past the last window of a Space SHALL flow into the first window of the next Space, animating the overlay's existing Space-row slide; advancing past the very last window overall SHALL wrap to the first window or clamp according to the existing wrap-at-ends setting. Stepping SHALL only move the highlight and scroll the overlay reel; it SHALL NOT perform a real Space switch (that happens on commit).

#### Scenario: Tab advances within a Space

- **WHEN** the selection is on a window that is not the last of its Space and the user presses Tab
- **THEN** the highlight moves to the next window in that Space

#### Scenario: Tab flows into the next Space

- **WHEN** the selection is on the last window of a Space and the user presses Tab
- **THEN** the overlay slides to the next Space-row and the highlight lands on that Space's first window
- **AND** the active Space is not actually switched (only the overlay reel scrolls)

#### Scenario: Wrap or clamp at the end of the reel

- **WHEN** the selection is on the very last window across all Spaces and the user presses Tab
- **THEN** with wrap-at-ends on, the highlight returns to the first window; with it off, the highlight stays on the last window

### Requirement: Shift+Tab steps the selection backward across Spaces

With the overlay open and ⌘ held, Shift+Tab SHALL step the selection backward by one window along the same flat reel order that Tab advances — the exact reverse of forward. Stepping backward past the first window of a Space SHALL flow into the previous Space's last window (animating the overlay's Space-row slide); stepping backward past the very first window overall SHALL wrap to the last window or clamp per the wrap-at-ends setting. This is symmetric with forward, not a jump-to-first.

#### Scenario: Shift+Tab steps backward within a Space

- **WHEN** the selection is not on the first window of its Space and the user presses Shift+Tab
- **THEN** the highlight moves to the previous window in that Space

#### Scenario: Shift+Tab flows backward into the previous Space

- **WHEN** the selection is on the first window of a Space and the user presses Shift+Tab
- **THEN** the overlay slides to the previous Space-row and the highlight lands on that Space's last window

### Requirement: Arrow keys navigate the open switcher

While the overlay is open and ⌘ is held, the arrow keys SHALL navigate it (Windows-Alt-Tab style): Left/Right SHALL step the selection backward/forward through windows exactly as Shift+Tab / Tab do (flowing across Spaces one window at a time), and Up/Down SHALL jump directly to the adjacent Space (landing on that Space's first window), matching the trackpad's vertical Space-switch direction. Arrow keys SHALL be consumed only while a session is open (so ⌘-arrow shortcuts are untouched when the switcher is closed) and SHALL NOT themselves open the switcher.

#### Scenario: Right/Left step through windows across Spaces

- **WHEN** the switcher is open and the user presses Right (or Left) with ⌘ held
- **THEN** the selection steps forward (or backward) one window along the same flat order Tab uses, flowing into the adjacent Space at a Space boundary

#### Scenario: Up/Down jump between Spaces

- **WHEN** the switcher is open and the user presses Up (or Down) with ⌘ held
- **THEN** the overlay jumps to the adjacent Space-row and lands on that Space's first window

#### Scenario: Arrows do not open the switcher and leave ⌘-arrow shortcuts alone

- **WHEN** ⌘ is held but the switcher is not open and the user presses an arrow
- **THEN** the arrow is not consumed (the normal ⌘-arrow shortcut reaches the focused app) and the switcher does not open

### Requirement: Releasing ⌘ commits the selection with a cross-Space raise

Releasing ⌘ while the overlay is open SHALL commit: it raises the highlighted window and, when that window is on a different Space than the active one, switches to that Space — reusing the existing cross-Space raise. On commit the overlay SHALL hide promptly.

#### Scenario: ⌘ release raises the highlighted window

- **WHEN** the overlay is open on a highlighted window and the user releases ⌘
- **THEN** the highlighted window is raised and focused, and the overlay hides

#### Scenario: Commit switches to the window's Space when off-Space

- **WHEN** the committed window is on a different Space than the active one
- **THEN** the system switches to that window's Space and raises it, exactly as raising any off-Space window does

### Requirement: Esc cancels and the overlay is always torn down

Pressing Esc while the overlay is open SHALL cancel: the overlay hides and no window is raised or Space switched; the Esc SHALL be consumed so it does not reach the focused application. Independently, if the session would otherwise be stranded open — a lost ⌘-release, the app resigning active, or the input tap being disabled — the overlay SHALL be torn down (canceled), never left visible.

#### Scenario: Esc dismisses without raising

- **WHEN** the overlay is open and the user presses Esc
- **THEN** the overlay hides, nothing is raised or switched, and the Esc does not reach the focused application

#### Scenario: Stranded session is torn down

- **WHEN** a keyboard switcher session is open and the app resigns active (or the input tap is disabled) before a ⌘-release is seen
- **THEN** the overlay is torn down and nothing is committed

### Requirement: One switcher session at a time

The keyboard driver and the trackpad gesture SHALL share the switcher such that only one owns it at a time. While a trackpad switcher gesture holds the overlay, the keyboard driver SHALL NOT act on ⌘-Tab; while a keyboard session holds the overlay, the trackpad path SHALL be unaffected. After a session ends (commit or cancel), either driver SHALL be able to open the switcher again.

#### Scenario: Keyboard driver defers to an active trackpad gesture

- **WHEN** a trackpad switcher gesture is holding the overlay open and the user presses ⌘-Tab
- **THEN** the keyboard driver takes no action on the overlay

#### Scenario: Either driver can reopen after a session ends

- **WHEN** a keyboard session has just committed or canceled
- **THEN** a subsequent ⌘-Tab (or trackpad gesture) opens the switcher normally

### Requirement: Browsing never stalls the input pipeline

The keyboard tap's callback SHALL stay cheap: the repeated, per-keystroke browsing work a Tab triggers — the window snapshot, overlay presentation, and thumbnail capture — SHALL run off the tap callback (deferred to the app's main run loop), so intercepting ⌘-Tab never stalls the system's synchronous event dispatch or degrades concurrent input such as the trackpad gesture and the moving highlight. The open, step, commit, and cancel intents SHALL all defer onto the main run loop so they drain in FIFO order (open → step → commit), so that even a fast ⌘-Tab press-release resolves — the commit runs after the open that showed the overlay and always dismisses it (a synchronous commit would race ahead of the deferred open and strand the overlay on screen). The committed window keeping focus across a Space crossing SHALL NOT depend on the commit being synchronous: it is guaranteed by the raise path's polling focus hold-guard, which re-fronts the target for a bounded window after every off-Space raise regardless of when the raise fires.

#### Scenario: Browsing a Tab does not block event dispatch

- **WHEN** a Tab opens or steps the switcher
- **THEN** the tap callback returns without performing the snapshot / presentation / capture inline; that work runs on the app's main run loop, so trackpad input and highlight rendering stay responsive

#### Scenario: The committed window keeps focus across a Space switch

- **WHEN** ⌘ is released to commit onto a window on another Space
- **THEN** that window is raised and RETAINS focus (it is not stolen back by the destination Space), because the raise path's polling focus hold-guard re-fronts the target for a bounded window after the off-Space raise — independent of when (or how promptly) the deferred commit fires

### Requirement: No new permission and a self-healing tap

The keyboard driver SHALL require no permission beyond the Input Monitoring the app already holds, and SHALL NOT require a re-login to enable or disable. The keyboard event tap SHALL re-enable itself if the system disables it (tap timeout or user-input disable), so interception survives the system's periodic tap suspensions.

#### Scenario: No new grant is requested

- **WHEN** the user enables the feature and Input Monitoring is already granted
- **THEN** interception begins with no additional permission prompt and no re-login

#### Scenario: Tap self-heals after the system disables it

- **WHEN** the system disables the keyboard event tap (timeout or user-input disable)
- **THEN** the tap is re-enabled and ⌘-Tab interception continues

