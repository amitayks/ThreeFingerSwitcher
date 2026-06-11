## Context

`per-app-keyboard-language` already remembers an input source per application and restores it on activation, using a **learn-on-deactivation / apply-on-activation** engine: on every `NSWorkspace.didActivateApplication`, read the current source once, learn it for the outgoing app, apply the incoming app's remembered source. The store is a `[contextKey: InputSourceID]` map (currently `contextKey == bundleID`); the policy (`activate`/`learn`) and store are already plain string-keyed.

A browser breaks the "one app = one place" assumption: Chrome hosts `keep.google.com` (wants Hebrew) and `mail.google.com` (wants English) in the same process. The user wants **host-level** memory inside browsers. The insight is that the engine is already context-agnostic — it just needs (1) a resolver that produces `bundleID|host` for browser contexts, and (2) a signal that fires on within-browser host changes (which produce no `NSWorkspace` event).

Two facts constrain the host reader:
- The app already has **Accessibility**; it has **no** Automation/Apple Events grant.
- **Safari shows only the registrable domain in its address bar** (subdomain hidden), so an AX read of Safari's address bar cannot distinguish `keep.` from `mail.google.com`. Chrome's omnibox exposes the full host. So AX gives host-level precision on Chrome/Chromium but only domain-level on Safari; Apple Events gives exact hosts everywhere.

## Goals / Non-Goals

**Goals:**
- Inside supported browsers, remember/apply the input source per active-tab **host**, learned on host change, reusing the per-app store/policy/learn/apply unchanged.
- Default to **no new permission** (Accessibility reader); offer an **opt-in Apple Events** reader for exact hosts incl. Safari.
- Keep the host reader behind a testable seam (like `InputSourceController`); keep `BrowserRegistry`/resolution pure and unit-tested.
- Privacy: read only the host, skip private/incognito, ignore the address bar while it's being typed in.
- Off by default; a sub-toggle of the existing feature. Non-browser apps and the per-site-off case behave exactly as today.

**Non-Goals:**
- Per-page / per-path memory, and registrable-domain grouping (host is the unit, per product decision).
- Firefox exactness (no scriptable URL; best-effort AX only).
- Reading the full URL or storing browsing history.
- An AX title-change observer in v1 (polling first; observer is a later optimization).
- Cross-device sync.

## Decisions

### D1: Generalize the engine key from bundle id to a context id
Introduce a `ContextResolver` that maps the frontmost app to a context id: `bundleID` for a normal app, `bundleID + "|" + host` for a supported browser whose host resolves. `KeyboardLanguageService.handleActivation(bundleID:)` becomes `handleContextChange(contextID:)`; the store/policy are untouched (still string-keyed). Per-app entries (`com.telegram`) and per-site entries (`com.google.Chrome|keep.google.com`) coexist in the same map.
- *Alternative — a second parallel store for sites:* duplicates the engine; rejected. One map, richer keys.

### D2: Host-level keys (subdomain-specific), no public-suffix list
The key's host segment is the full hostname as resolved (`keep.google.com`), lowercased, `www.` optionally stripped. No eTLD+1 computation → no public-suffix list to ship/maintain. This is exactly the user's requirement (Keep ≠ Gmail).

### D3: `HostProvider` seam with two implementations
```
protocol HostProvider { func host(forBrowser bundleID: String) -> String? }  // nil = unknown/none
```
- **`AXHostProvider` (default):** read the browser's focused-window address-bar element via Accessibility; parse its value to a host. Guards: return nil if the address bar is **focused/being edited** (value is the user's typed text, not a host) and if the window is **private/incognito** (detectable by window/subrole heuristics). Host-level on Chrome/Chromium; domain-level on Safari (accepted degradation, D7).
- **`AppleEventsHostProvider` (opt-in):** in-process Apple Events — `URL of active tab of front window` (Chrome family) / `URL of current tab of front window` (Safari) — parsed to a host. `AEDeterminePermissionToAutomateTarget` checks/ages the grant so a denied/undetermined state degrades gracefully (fall back to AX, never block). Exact host everywhere incl. Safari.
- Faked in tests (`FakeHostProvider` returns scripted hosts).
- *Alternative — always Apple Events:* best data but forces a scary per-browser permission on everyone; rejected as the default.

### D4: Within-browser signal = poll while a supported browser is frontmost
A `BrowserContextMonitor` (Timer, `pollInterval` ~0.4–0.6s, pausable) runs **only while a supported browser is frontmost**. Each tick re-resolves the context id; on change it drives the existing learn-outgoing/apply-incoming path. Mirrors `ClipboardMonitor` exactly. Stops when the front app isn't a supported browser (app switches are still caught by the existing `didActivateApplication` path).
- *Alternative — AX `kAXTitleChangedNotification` observer:* event-driven, zero idle cost, but per-process AX wiring and inconsistent firing; deferred as a refinement (Non-Goal).

### D5: Browser registry is a small pure table
`BrowserRegistry`: bundle id → `{ supported, scriptName, family }` for Safari (`com.apple.Safari`) and Chromium forks (`com.google.Chrome`, `com.brave.Browser`, `com.microsoft.edgemac`, `company.thebrowser.Browser` (Arc), `com.vivaldi.Vivaldi`). Pure and unit-tested. Firefox absent (best-effort/unsupported).

### D6: Fallback for an unseen host
Resolving a browser context with no stored entry falls back to the **global default** (then leave-as-is if unset) — identical to the per-app "unseen app" rule. No separate browser-app tier in v1 (could be added later: host → browser-app → global).

### D7: Safari AX degradation is defined behavior, not a bug
With the AX (default) reader, Safari yields the registrable domain, so all subdomains of a site share one entry on Safari. This is specified explicitly. The Apple-Events opt-in is the documented path to exact per-host on Safari. Chrome/Chromium get host-level under AX already.

### D8: Reuse persistence + opt-in wiring
The shared `KeyboardLanguageStore` already persists arbitrary string keys, so per-site entries need no schema change. Two new `AppSettings` scalars — `perSiteLanguageEnabled` (sub-toggle) and `allowBrowserControl` (Apple Events opt-in) — gate the monitor and the provider choice; the `AppCoordinator` starts/stops the `BrowserContextMonitor` like `ClipboardMonitor`.

### D9: Per-site learns only deliberate changes (added after first testing)
Per-app uses learn-on-deactivation: it records each app's *last-used* source, always. Applying that verbatim to sites is wrong — you visit hundreds of sites, so it would record an entry for every site you merely passed through, bloating the store and the new saved-sites list. So per-site learning is narrowed: the engine tracks the source each context **settled on** when entered (what `applyIncoming` applied), and on leaving a *site* key it persists ONLY if the current source differs from that settled source — i.e. the user actively changed the site's language. A change back to the global default removes the entry. Per-app keys keep the always-record behavior unchanged (the branch keys off `ContextKey.isSiteKey`). This makes the saved-sites list equal "sites you deliberately set," matching the product requirement.
- *Alternative — store every visited site, filter the list display:* leaves the store unbounded and the data dishonest; rejected.
- *Alternative — compare to the global default instead of the settled source:* fails when no global default is set; the settled-source signal is default-independent.

### D10: Saved-sites list is the per-site transparency + edit surface
The Hub's Keyboard Language page lists the store's site entries (keys carrying a host), each with the host, browser name, an inline language picker, and a remove control. It observes `KeyboardLanguageStore.shared` directly (the same instance the service writes), so it updates live as sites are learned. Beyond editing, it is the **diagnostic** for whether in-browser detection works at all: an empty list after changing a site's language means the host reader isn't catching the address (AX limits / browser control off) — the empty-state copy says exactly that.

## Risks / Trade-offs

- **Privacy: continuous host reads while browsing** → store only the host (never URLs/history), local only, opt-in, skip private/incognito. A per-site list in the Hub doubles as a transparency/edit surface (future).
- **AX address bar is fragile** (focus/typing state, layout differences, formatted values) → focus/typing guard + per-browser parsing; when a host can't be resolved cleanly, resolve to the app-level context (no host) rather than guessing — never learn under a wrong key.
- **Safari subdomain collapse under AX** → defined behavior (D7); Apple-Events opt-in is the fix; surfaced in the Hub copy.
- **Apple Events permission denied/undetermined** → `AEDeterminePermissionToAutomateTarget`; on anything but "granted", fall back to AX silently (no modal, consistent with the feature's silent-best-effort ethos).
- **Poll cost** → only while a supported browser is frontmost, throttled, pausable; one in-process AX/AE read per tick. Negligible.
- **Host churn while a page redirects** → debounce is implicit (we act on the resolved host per tick; transient intermediate hosts may learn/apply once but self-correct on the next tick). Acceptable.
- **Incognito detection imperfect across browser updates** → if unsure, prefer NOT reading the host (treat as app-level context) so we never record a private host.

## Migration Plan

Additive and opt-in. No store schema change (same string-keyed map). New UserDefaults keys only. Rollback = turn the sub-toggle off → the `BrowserContextMonitor` stops and browsers revert to per-app behavior; existing `bundleID|host` entries become inert (a non-browser-context lookup never consults them). Turning off "Allow browser control" reverts the reader to AX. No data migration.

## Open Questions

- ~~`www.` stripping and trailing-dot normalization rules~~ — **resolved.** `HostNormalizer` extracts the host from whatever the address bar yields (a bare host, a `host/path`, or a full URL) via `URLComponents` (prepending `https://` when there's no scheme), then lowercases, drops a trailing `.`, strips one leading `www.`, and requires a dotted host (rejecting `chrome://newtab` → `newtab`, search terms, etc.). This was the fix for the original bug where a sub-page URL like `claude.ai/chat/1552f48` (omnibox shows host+path) was rejected for containing `/` and collapsed to the bare browser app key — the language is set on, and matched against, the **host root** regardless of path.
- Whether unseen hosts should later fall back to the browser's app-level remembered language (host → app → global) instead of straight to the global default (D6 keeps it simple for now).
- Reliable private/incognito detection signals per browser family (AX window subrole / title markers vs Apple Events window properties).
