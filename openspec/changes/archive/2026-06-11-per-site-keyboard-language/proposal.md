## Why

The per-app keyboard-language feature remembers one input source per application — but a browser is many "places". A user wants Hebrew on `keep.google.com` and English on `mail.google.com`, yet both are the same app (Chrome), so per-app memory collapses them into one. This change extends the same learn/apply engine to remember the input source **per site (host) inside browsers**, so the keyboard follows the *page*, not just the app.

## What Changes

- Extend per-app keyboard-language so that, inside supported browsers, the unit of memory is the **app + active tab's host** (e.g. `com.google.Chrome|keep.google.com`) instead of just the app. Non-browser apps are unchanged.
- **Host-level granularity** (subdomain-specific): `keep.google.com` and `mail.google.com` are independent. No registrable-domain grouping, no per-page/path keys.
- **Two ways to read the active host, behind a seam:**
  - **Accessibility (default, no new permission):** read the browser's address-bar value via the AX API the app already holds. Works at host level on Chrome/Chromium; on Safari (which shows only the registrable domain in the address bar) it degrades to per-domain.
  - **Apple Events (opt-in):** script the browser for the exact URL → exact host **everywhere, including Safari**. Gated behind a new "Allow browser control" consent that triggers the per-browser Automation permission.
- **Within-browser change detection:** while a supported browser is frontmost, poll the active host (mirroring the clipboard monitor) and treat a host change like an app switch — learn the outgoing host's source, apply the incoming host's source.
- A small **browser registry** (Safari, Chrome, and Chromium forks: Brave, Edge, Arc, Vivaldi). Firefox is unsupported/best-effort.
- **Privacy guards:** read only the host (never full URLs or history); skip **private/incognito** windows; ignore the address bar while it is focused/being typed in.
- **Hub:** a "Per-site language in browsers" sub-toggle (under the existing feature) and an "Allow browser control (exact per-site in Safari)" opt-in row.
- Off by default; when the per-site sub-toggle is off, browsers behave exactly as today (per-app).

## Capabilities

### New Capabilities
- `per-site-keyboard-language`: Inside supported browsers, remember and auto-apply the keyboard input source per active-tab host, learned on host change, with an Accessibility-based host reader (default) and an opt-in Apple Events reader for exact hosts (incl. Safari), private-window/typing guards, and Hub controls. Built on the per-app engine (shared store, policy, learn-on-deactivation/apply-on-activation).

### Modified Capabilities
<!-- None on disk: the per-app-keyboard-language capability is not yet archived into openspec/specs/, so its requirements are not modified here. This change adds the per-site layer as a new capability; the implementation generalizes the shared engine (bundle-id key → context key) without changing per-app behavior. -->

## Impact

- **Engine generalization (Core, MLX-free, tested):** the keyboard-language engine's key generalizes from `bundleID` to a **context id** (`bundleID` for normal apps, `bundleID|host` for browser contexts). A pure `BrowserRegistry` (bundle id → supported?) and a `ContextResolver` produce the context id. The shared `KeyboardLanguageStore`/`KeyboardLanguagePolicy` are unchanged (already string-keyed).
- **New seam:** `HostProvider` protocol (`host(forBrowserBundleID:) -> String?`) with two impls — `AXHostProvider` (default; reads the address bar via Accessibility, with focus/typing and private-window guards) and `AppleEventsHostProvider` (opt-in; in-process Apple Events, `AEDeterminePermissionToAutomateTarget` to check the grant). Faked in tests.
- **New signal:** a poll-while-browser-frontmost monitor (Timer/`pollInterval`/pausable, mirroring `ClipboardMonitor`) that re-resolves the context and drives the existing learn/apply path on host change.
- **AppSettings:** new scalars — `perSiteLanguageEnabled` (sub-toggle, default off) and `allowBrowserControl` (Apple Events opt-in, default off).
- **Hub:** the sub-toggle + the browser-control opt-in row on the Keyboard Language page.
- **Permissions:** Accessibility (already granted) for the default path; Automation/Apple Events only when the opt-in is enabled (a new TCC prompt per browser). No new third-party dependencies.
- **No behavior change** for non-browser apps or when the per-site sub-toggle is off.
