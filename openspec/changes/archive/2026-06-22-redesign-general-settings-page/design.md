## Context

The Hub's **General** page (`HubFeaturePages.swift` → `GeneralPage`) currently stacks three single-toggle cards (Reliability / Startup / Diagnostics) plus a Danger zone. Each preference uses a default `Toggle`, which renders as a checkbox in this layout. The Diagnostics card additionally hosts two action buttons inline — **Write Diagnostics → /tmp** and **Copy Focus Log** — gated by the `showDiagnostics` preference.

The menu-bar status menu (`StatusItemController.rebuildMenu`) is deliberately minimal: Open Hub, switcher toggle, Add Front App to Band ▸, Quit. The `menubar-app-shell` spec currently states diagnostics live on the Hub's General page and never in the status menu. This change reverses that: the diagnostic *actions* belong with the app's other quick actions in the status menu, and the General page's "Show diagnostic tools" preference governs their *visibility there*.

Supporting facts already in place:
- `AppCoordinator` exposes `writeDiagnostics()` and `copyFocusLog()` (`AppCoordinator.swift:426,440`); the Hub context closures `onWriteDiagnostics` / `onCopyFocusLog` route to them.
- `AppSettings.showDiagnostics` is an existing persisted `@Published Bool` (default `false`).
- `StatusItemController` already holds the `coordinator` and rebuilds the menu on every open via `menuNeedsUpdate(_:)` → `rebuildMenu()`.

## Goals / Non-Goals

**Goals:**
- One consolidated **"General"** section of switch-style preference rows (Self-heal, Open at Login, Show diagnostic tools).
- Diagnostic actions surface in the **menu-bar status menu** when `showDiagnostics` is on; nowhere when off (default).
- Danger-zone selectors rendered as a 2×2 grid of full-body, click-to-highlight toggle-cards, with identical selection/clear behavior.

**Non-Goals:**
- No change to what the diagnostic actions *do* (`writeDiagnostics()` / `copyFocusLog()` are untouched).
- No new persisted keys, no new permissions, no gesture relocation.
- No change to the Danger-zone selection model, confirmation flow, Clear-selected gating, or Restore-native-gestures action.
- No restyle of other Hub pages or the Overview master toggles.

## Decisions

### D1 — "Action menu" = the menu-bar status menu; reverse `menubar-app-shell`
The diagnostic actions move into `StatusItemController.rebuildMenu()` as their own group placed **before Quit**, appended only when `showDiagnostics` is on. The pre-existing `menubar-app-shell` requirement (diagnostics live on the General page, never in the menu) is rewritten. Default-off behavior is preserved: with the preference off, the actions appear in neither the menu nor the page.
- *Alternative considered:* keep diagnostics on the page (status quo). Rejected — the user wants the page's toggle to gate *menu* visibility, matching how every other quick action lives in the status menu.

### D2 — Menu reflects the preference at rebuild time; no live observer needed
`StatusItemController.menuNeedsUpdate(_:)` already calls `rebuildMenu()` every time the menu is about to open, so reading `coordinator.showDiagnostics` inside `rebuildMenu()` is sufficient — the menu always reflects the current preference the next time it opens. `AppCoordinator` exposes a `showDiagnostics` read accessor (delegating to `AppSettings`). No KVO/Combine wiring or `onStateChange` trigger on the preference is required.
- *Alternative considered:* observe `showDiagnostics` and force a rebuild on flip. Rejected as unnecessary — a closed menu has nothing to update, and it reopens rebuilt.

### D3 — A reusable `SwitchRow` for the consolidated section
Add a small `SwitchRow` view (title + optional caption on the left, `Toggle("", isOn:).labelsHidden().toggleStyle(.switch)` right-aligned, in an `HStack`) alongside the existing `ToggleRow`/`LabeledSlider` in `HubControls.swift`. The three preference rows live in one `HubSection("General")` separated by `Divider()`. The Open-at-Login row keeps its existing refresh-on-toggle binding.
- *Alternative considered:* add a `style` parameter to `ToggleRow`. Rejected — `ToggleRow`'s vertical layout (caption *under* a leading checkbox) differs from the right-aligned switch row; a dedicated view is clearer than a branching one.

### D4 — A `ToggleCard` for the Danger-zone 2×2 grid
Add a `ToggleCard` view: a full-body button (whole card is the hit target) showing a title + caption, bound to a `Bool`; the selected state renders a highlight (tinted fill/stroke). Lay the four cards out in a 2-column grid (`LazyVGrid` with two flexible columns, or two `HStack` rows). The existing four `@State` booleans and `dangerSelection` computed `DangerZoneSelection` are unchanged — only the widget swaps. The card exposes toggle/selected accessibility semantics.
- *Alternative considered:* keep `ToggleRow` checkboxes. Rejected — the user asked for the grid; cards also make the multi-select read as deliberate.

## Risks / Trade-offs

- **Destructive cards could read like harmless on/off switches** → Mitigation: the Danger-zone cards use a distinct selected-highlight (not a switch), sit under the existing **"Danger zone"** title, and remain gated by the red, confirmation-bearing **Clear selected…** action — so a selection never deletes anything on its own.
- **Switch vs checkbox semantic shift** for the three preferences → low risk: all three are genuine immediate on/off settings, which is exactly what a switch signals; no multi-select semantics are implied.
- **Menu shows stale state if the preference flips while the menu is open** → not possible in practice: a macOS menu rebuilds on open (`menuNeedsUpdate`), and the General page can't be interacted with while the status menu is tracking.
- **Diagnostics discoverability moves** from an always-visible page section to an opt-in menu group → acceptable and intended; the page caption tells the user where they now appear, and they are a troubleshooting aid that is off by default.
