# window-enumeration-and-raising — delta for refine-window-filtering

## ADDED Requirements

### Requirement: Window switchability filtering

The system SHALL decide whether a resolved window element is listed via a pure, unit-testable filter that consumes the window's observable facts — role, subrole, title, Accessibility (real) size, presence of window chrome (a close button), and minimized state — plus a policy derived from the global settings and any per-app rule, and SHALL produce a typed verdict carrying a drop reason when the window is not listed.

In **strict** mode (the `includeNonStandardWindows` toggle off, no per-app override) verdicts SHALL be unchanged from before this change: a window-role element with the standard-window subrole (or no subrole) is listed; other subroles are not; minimized windows follow the include-minimized opt-in.

In **relaxed** mode the filter SHALL be three-tier and SHALL be monotonic over strict — every window strict mode lists, relaxed mode also lists:

1. Known-real subroles (standard window, dialog, system dialog) are always listed.
2. Known-junk subroles (floating and system-floating palettes) are always dropped.
3. A window reporting NO subrole at all is listed (strict mode lists these — monotonicity). Any other unrecognized subrole (unknown / novel toolkit values) is listed only when the window shows identity — a non-empty title OR window chrome (a close button) — and dropped as phantom otherwise. Size SHALL NOT be a sufficient signal on its own: the AirDrop share popover births untitled, chromeless clones at the host window's exact frame (three per attempt, host-app-owned, lingering after dismissal), which defeat any "big enough to be real" bar.

A degenerate-size floor (minimum side below 40pt) SHALL drop sliver/zero frames in relaxed mode before the tiers apply.

**Per-app rules** SHALL override the global policy per application, keyed by bundle identifier (falling back to executable name when absent): `include` lists every window-role element of the app (bypassing the junk heuristics and duplicate suppression; the degenerate floor still applies), `strict` applies the strict gate regardless of the global toggle, and `exclude` lists no windows of the app. The rules SHALL apply to every window-listing surface that uses the switchability gate — the switcher snapshot, ⌘-Tab, the Dock preview enumeration, and minimize-all (an excluded app's windows are not minimized, so no window is ever stranded behind a filter).

**Phantom-duplicate suppression:** windows of the same application with the same normalized title, the same integral real (Accessibility) frame, and the same minimized state SHALL be collapsed to a single listing, keeping the frontmost (lowest z-order; where z is unavailable, a stable id order). Suppression SHALL apply in strict and relaxed mode alike and in every enumeration (all-Spaces snapshot, legacy snapshot, Dock preview), and SHALL be bypassed for apps with the `include` rule.

#### Scenario: Small standard window is listed in relaxed mode

- **WHEN** relaxed mode is on and a standard-subrole window's height is below the legacy 100pt threshold (a copy-progress window)
- **THEN** the window is listed — relaxation never drops a window strict mode would list

#### Scenario: Titled or chromed unknown window is listed

- **WHEN** relaxed mode is on and a window with an unknown subrole has a non-empty title or a close button (the emulator's titled device window, a small titled progress window)
- **THEN** the window is listed regardless of its size

#### Scenario: Untitled chromeless unknown window is dropped as phantom regardless of size

- **WHEN** relaxed mode is on and a window-role element has an unknown subrole, an empty title, and no close button — whether small (the emulator side-toolbar) or host-window-sized (an AirDrop share popover clone)
- **THEN** the window is dropped with the phantom reason

#### Scenario: Missing subrole stays listed

- **WHEN** relaxed mode is on and a window reports no subrole at all, even untitled and chromeless
- **THEN** the window is listed (strict mode lists these, and relaxation never drops a window strict lists)

#### Scenario: Phantom duplicates collapse to one card

- **WHEN** an application exposes several window objects with the same title, the same integral real frame, and the same minimized state (the AirDrop send popup's clones)
- **THEN** exactly one is listed — the frontmost — in the switcher and in the Dock preview alike

#### Scenario: Distinct same-app windows are not collapsed

- **WHEN** two windows of one application differ in title or in frame
- **THEN** both are listed

#### Scenario: Excluded app lists nothing

- **WHEN** an app has the `exclude` rule
- **THEN** none of its windows appear in the switcher, ⌘-Tab, or the Dock preview, and minimize-all does not minimize them

#### Scenario: Include rule bypasses heuristics and dedup

- **WHEN** an app has the `include` rule and relaxed heuristics or duplicate suppression would drop one of its windows
- **THEN** the window is listed anyway (only the degenerate-size floor still applies)

#### Scenario: Strict per-app rule under a relaxed global

- **WHEN** the global relaxed toggle is on and an app has the `strict` rule
- **THEN** only that app's standard-subrole windows are listed
