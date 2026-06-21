## ADDED Requirements

### Requirement: Gesture feature pages lead with a live preview and a switch-style master toggle
Each **gesture-driven** feature page in the Hub (Window Switcher, Launcher, Clipboard, Files, AI Commands) SHALL lead with a live gesture preview (per the `hub-gesture-previews` capability) and, **directly beneath it**, the feature's master enable as a **switch-style row** matching the Overview "home page" toggle (icon + title + subtitle + a `.switch` toggle), writing the same persisted preference as before. The existing per-feature tunables, pickers, and buttons below the master toggle SHALL be **preserved unchanged** — same bindings, same persistence, same look/feel/type. Gestureless pages (Keyboard Language, Devices, Setup, General) are not in scope for this requirement.

#### Scenario: A gesture page leads with preview then switch toggle
- **WHEN** the user opens a gesture-driven feature page (e.g. Window Switcher)
- **THEN** a live gesture preview appears first, with the feature's master enable as a switch-style row directly beneath it

#### Scenario: The master toggle still writes the same preference
- **WHEN** the user flips the switch-style master toggle on a feature page
- **THEN** the same persisted preference is written as toggling that feature on the Overview page or via the prior toggle

#### Scenario: Secondary controls are unchanged
- **WHEN** the user views the controls below the master toggle (sliders, pickers, buttons)
- **THEN** they retain their existing behavior, bindings, and presentation

### Requirement: Remappable pages expose gesture-binding controls
Feature pages whose surface has configurable resolution gestures (AI Commands, Files, Window Switcher) SHALL present **binding controls** (per-action dropdowns) alongside the preview, editing the `gesture-bindings` for that surface. Hovering a binding option SHALL demo it in the preview; the controls SHALL enforce the per-surface mutual-exclusivity and reserved-excursion rules.

#### Scenario: AI page exposes canvas resolve bindings
- **WHEN** the user opens the AI Commands page
- **THEN** dropdowns let the user map commit / dismiss / ignore to canvas excursions, with hover-to-demo in the preview

#### Scenario: Files page exposes drill resolution bindings
- **WHEN** the user opens the Files page
- **THEN** dropdowns let the user map open / Open-With / discard to the drill's excursions

#### Scenario: Switcher page exposes scrub-direction bindings
- **WHEN** the user opens the Window Switcher page
- **THEN** controls let the user set the windows and Spaces scrub directions (normal / reversed), replacing the standalone reverse toggles
