## ADDED Requirements

### Requirement: Per-site memory keyed by app + active-tab host
While the per-site sub-feature is enabled, the system SHALL, inside a supported browser, use the active tab's **host** combined with the browser's bundle identifier as the unit of keyboard-language memory (e.g. `com.google.Chrome|keep.google.com`). The host SHALL be subdomain-specific: `keep.google.com` and `mail.google.com` SHALL be remembered independently. The system SHALL NOT key on the full URL/path, and SHALL NOT group subdomains under a registrable domain. Non-browser applications SHALL continue to be keyed by bundle identifier alone.

#### Scenario: Two hosts in the same browser are independent
- **WHEN** the user uses Hebrew on `keep.google.com` and English on `mail.google.com` in the same browser
- **THEN** each host remembers its own input source, and returning to either restores that host's source

#### Scenario: Non-browser apps are unaffected
- **WHEN** the frontmost app is not a supported browser
- **THEN** memory is keyed by bundle identifier exactly as the per-app feature already does

### Requirement: Learn on host change, apply on host change
While the per-site sub-feature is enabled and a supported browser is frontmost, the system SHALL detect when the active host changes (tab switch or navigation) and SHALL treat it like an application switch: capture (learn) the outgoing host's input source per the "only actively-changed sites" rule below, then select (apply) the incoming host's remembered source. Switching the active tab back to a host with no remembered change SHALL NOT spuriously overwrite that host's memory.

#### Scenario: Navigating to another site applies that site's language
- **WHEN** the user is on a host remembered as Hebrew and navigates/switches to a host remembered as English
- **THEN** the input source switches to English

#### Scenario: Leaving a site the user changed captures the source used there
- **WHEN** the user changes the input source while on a host and then switches to a different host or app
- **THEN** the source in use is remembered for the host that was left

### Requirement: Only sites the user actively changed are remembered
Unlike per-app memory (which records each app's last-used source), the system SHALL remember a browser host's language ONLY when the user actively changed it — that is, when the source on leaving the host differs from the source the system applied/settled on when the host became active. A host the user merely visited at its applied language SHALL NOT be recorded. If the user changes a remembered host's language back to the global default, the system SHALL forget that host (remove its entry), since it is no longer a deliberate per-site choice.

#### Scenario: A visited-but-unchanged site is not saved
- **WHEN** the user navigates to a site, leaves its keyboard language at whatever was applied, and moves on
- **THEN** that site is not added to the saved per-site memory

#### Scenario: A site whose language was changed is saved
- **WHEN** the user changes the keyboard language while on a site and then leaves it
- **THEN** that site is remembered with the changed source

#### Scenario: Reverting a site to the global default forgets it
- **WHEN** the user changes a previously remembered site's language back to the global default and leaves it
- **THEN** the site's entry is removed (it is no longer a saved site)

### Requirement: Saved-sites list in the Hub
When the per-site sub-feature is enabled, the Keyboard Language Hub page SHALL show a list of the saved per-site entries — and only those (per-app entries SHALL NOT appear). Each row SHALL show the site host (and which browser it belongs to) and the language remembered for it, SHALL let the user change that language inline, and SHALL let the user remove the entry. When no per-site entries exist, the list SHALL show guidance that doubles as a detection check (if it stays empty after the user changes a site's language, the browser's address is not being read and browser control should be enabled).

#### Scenario: Saved sites are listed with their language, editable
- **WHEN** per-site is enabled and at least one site has a remembered language
- **THEN** the Hub lists each saved site with its host, browser, and remembered language, each with an inline language control and a remove control

#### Scenario: Empty list explains how to populate and verify detection
- **WHEN** per-site is enabled and no site has been saved yet
- **THEN** the Hub shows guidance to change a site's language in a supported browser, noting that a persistently empty list means the address isn't being read (enable browser control, required for Safari)

#### Scenario: Changing or removing an entry updates memory
- **WHEN** the user changes a listed site's language or removes its row
- **THEN** the per-site memory is updated accordingly (the new source is remembered, or the entry is forgotten)

### Requirement: Accessibility host reader is the default (no new permission)
By default the system SHALL read the active host using the Accessibility API it already holds, requiring no new permission. The system SHALL ignore the address bar while it is focused or being edited (its value is the user's typed text, not a committed host) and SHALL skip private/incognito windows. When a host cannot be resolved cleanly, the system SHALL fall back to the app-level (bundle-identifier) context rather than guess, so memory is never written under an incorrect key.

#### Scenario: Default path needs no Automation permission
- **WHEN** the per-site sub-feature is enabled without enabling browser control
- **THEN** the active host is read via Accessibility and no Automation/Apple Events permission is requested

#### Scenario: Address bar being typed in is not treated as a host
- **WHEN** the user is typing into the address bar (it is focused/edited)
- **THEN** the typed text is not interpreted as a host and no per-site learn/apply occurs from it

#### Scenario: Private/incognito windows are skipped
- **WHEN** the frontmost browser window is a private/incognito window
- **THEN** the system does not read or record its host

### Requirement: Apple Events reader is an opt-in for exact hosts including Safari
The system SHALL offer an opt-in "allow browser control" mode that reads the exact active-tab URL via Apple Events, yielding the exact host on all supported browsers including Safari. This mode SHALL be off by default and SHALL request the per-browser Automation permission only when enabled. If that permission is denied or undetermined, the system SHALL fall back to the Accessibility reader silently (no blocking modal).

#### Scenario: Opt-in gives exact per-host on Safari
- **WHEN** browser control is enabled and granted, and the user visits `keep.google.com` then `mail.google.com` in Safari
- **THEN** the two hosts are distinguished and remembered independently

#### Scenario: Denied Automation permission degrades gracefully
- **WHEN** browser control is enabled but the Automation permission is denied or not yet granted
- **THEN** the system falls back to the Accessibility host reader without showing a blocking error

### Requirement: Safari Accessibility reading degrades to registrable domain
When using the default Accessibility reader on Safari (whose address bar shows only the registrable domain), the system SHALL treat the registrable domain as the host for keying purposes. This SHALL be defined behavior, not an error: all subdomains of a site share one entry on Safari under the Accessibility reader, and the Apple Events opt-in is the supported path to exact per-host on Safari.

#### Scenario: Safari subdomains collapse under the Accessibility reader
- **WHEN** browser control is OFF and the user visits `keep.google.com` and `mail.google.com` in Safari
- **THEN** both resolve to the same `google.com`-level entry (one remembered source for the site), without error

#### Scenario: Chrome keeps host-level under the Accessibility reader
- **WHEN** browser control is OFF and the user visits `keep.google.com` and `mail.google.com` in Chrome
- **THEN** the two hosts are distinguished and remembered independently

### Requirement: Supported-browser registry
The system SHALL recognize a fixed set of supported browsers by bundle identifier — Safari and the Chromium family (Chrome, Brave, Microsoft Edge, Arc, Vivaldi) — and SHALL apply per-site behavior only when the frontmost app is in that set. Unsupported browsers (e.g. Firefox) and non-browser apps SHALL use per-app behavior unchanged.

#### Scenario: A supported browser triggers per-site behavior
- **WHEN** a supported browser (e.g. Chrome) is frontmost and the sub-feature is enabled
- **THEN** the active host is resolved and used for keying

#### Scenario: An unsupported browser uses per-app behavior
- **WHEN** an unsupported browser (e.g. Firefox) is frontmost
- **THEN** memory is keyed by bundle identifier alone (no host)

### Requirement: Off by default and gated by its own sub-toggle
Per-site behavior SHALL be controlled by a "per-site language in browsers" sub-toggle, off by default, beneath the existing keyboard-language feature. While the sub-toggle is off (or the parent feature is off), browsers SHALL behave exactly as the per-app feature does today, and the system SHALL NOT poll or read browser hosts. Turning the sub-toggle off SHALL stop all browser host monitoring.

#### Scenario: Disabled sub-feature leaves browsers as per-app
- **WHEN** the per-site sub-toggle is off
- **THEN** no browser host is read or polled, and a browser is remembered by bundle identifier like any other app

#### Scenario: Turning the sub-feature off stops monitoring
- **WHEN** the user turns the per-site sub-toggle off
- **THEN** the browser host monitor stops and no further host reads occur

### Requirement: Hub controls for per-site
The Keyboard Language Hub page SHALL expose a "Per-site language in browsers" toggle and an "Allow browser control" opt-in (which enables the Apple Events reader for exact per-site, including Safari). The copy SHALL make clear that the default works at host level on Chrome/Chromium and at domain level on Safari until browser control is enabled.

#### Scenario: Hub exposes the sub-toggle and the opt-in
- **WHEN** the user opens the Keyboard Language page
- **THEN** a per-site toggle and an "allow browser control" opt-in are shown, with copy explaining the Safari difference
