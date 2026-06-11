import AppKit

/// The engine that ties the store, the pure `KeyboardLanguagePolicy`, and the Carbon
/// `InputSourceController` seam together for the per-app **and** per-site keyboard-language feature.
///
/// **Learn on deactivation, apply on activation.** Everything is driven by a change of **context** —
/// an app switch (`NSWorkspace.didActivateApplicationNotification`) or, within a supported browser, a
/// host change surfaced by `reevaluate()` — and pivots on a single read of the current input source
/// taken *before* we change anything:
/// - **Learn (the only write path, design D3):** at the instant the context changes, the OS still
///   reports the *outgoing* context's input source (nothing has changed it yet — we are the only thing
///   that does). So we read it once and record it for the context we are leaving. Attribution is
///   therefore deterministic: no asynchronous change notification to classify, and no feedback guard
///   (design D5). This is what makes a choice survive visiting another context and toggling its language.
/// - **Apply (design D6):** then select the now-current context's remembered source (or the global
///   default for an unseen context), short-circuiting a redundant select.
///
/// The engine is **context-agnostic**: it keys on an opaque context id supplied by `currentContextID`
/// (a plain app's id is its bundle id; a browser context's is `bundleID|host` — see `ContextResolver`),
/// so the per-app path is byte-for-byte unchanged and per-site is "just another key" (design D1).
///
/// The service is fully inert until `start()` and again after `stop()`: while stopped it holds no
/// observer and performs no TIS reads or writes (spec "Disabling stops all activity", design D9).
@MainActor
final class KeyboardLanguageService {
    private let store: KeyboardLanguageStore
    private let controller: InputSourceController
    private let globalDefault: () -> InputSourceID?
    private let currentContextID: () -> String?

    /// The NSWorkspace activation-observer token, held only while started (nil ⇒ inert).
    private var activationObserver: NSObjectProtocol?

    /// The context we currently treat as active — the one whose input source we capture ("learn") the
    /// moment the context changes (an app switch or a within-browser host change). Seeded on `start()`,
    /// updated on every context change, nil while stopped. nil also means "no prior context to learn"
    /// (the first activation).
    private var lastActiveContextID: String?

    /// The input source the active context *settled on* when we entered it — i.e. what `applyIncoming`
    /// applied (its remembered source, the global default, or the unchanged current source). Used to tell
    /// a deliberate user change apart from merely passing through: a **per-site** entry is only written
    /// when the source on leaving differs from this (the user actively changed the site's language), so
    /// the saved-sites list stays to deliberate choices, not every site visited. Per-app learning ignores
    /// it (an app always remembers its last-used source). Seeded in `start()`, nil while stopped.
    private var settledSourceForActiveContext: InputSourceID?

    /// - Parameters:
    ///   - globalDefault: the user's chosen global default source id, or nil/empty for "unset". An
    ///     empty string is normalized to nil so a blank `AppSettings` default reads as "no default".
    ///   - currentContextID: the resolved context id of the frontmost app — the bundle id for a normal
    ///     app, or `bundleID|host` for a supported browser (the coordinator resolves this through a
    ///     `ContextResolver`). Injected (no default) so the coordination logic is testable without a real
    ///     frontmost app or host reader: tests supply a closure that returns a scripted context id.
    init(store: KeyboardLanguageStore,
         controller: InputSourceController,
         globalDefault: @escaping () -> InputSourceID?,
         currentContextID: @escaping () -> String?) {
        self.store = store
        self.controller = controller
        self.globalDefault = globalDefault
        self.currentContextID = currentContextID
    }

    // MARK: - Lifecycle

    /// Begin observing app activations. Per spec, enabling makes NO retroactive change — it only seeds
    /// the baseline context (so the next change can learn it); the first real apply happens on the next
    /// context change, not on the current source.
    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Resolve the context of the now-frontmost app rather than trust the notification's bundle id:
            // the resolver may scope it to a host (browser), and it reads live state (the new frontmost).
            MainActor.assumeIsolated { self?.handleContextChange(contextID: self?.currentContextID()) }
        }
        // Seed the baseline WITHOUT touching the input source (spec "Enabling … without retroactive
        // change"): record the current context, and the source it is sitting on, so the next change can
        // tell whether the user actively changed this context's language.
        lastActiveContextID = currentContextID()
        settledSourceForActiveContext = controller.currentSourceID()
    }

    /// Re-resolve the current context and drive the learn/apply path if it changed. The within-browser
    /// poll monitor calls this each tick so a host change is handled exactly like an app switch — a host
    /// change emits no `NSWorkspace` notification, so this is the only signal for it (design D4). A
    /// no-change tick is the same cheap no-op as a same-context re-activation.
    func reevaluate() {
        handleContextChange(contextID: currentContextID())
    }

    /// Tear down the observer so the service is fully inert: no further TIS reads/writes and no
    /// activation callbacks (spec "Disabling stops all activity", design D9).
    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        lastActiveContextID = nil
        settledSourceForActiveContext = nil
    }

    // MARK: - Picker source list

    /// The user's selectable keyboard / input-method sources (id + localized name), forwarded from the
    /// controller seam so the Hub's global-default picker can list sources without the View importing
    /// Carbon directly (task 8.4). Read fresh on each render.
    func controllerEnabledSources() -> [(id: InputSourceID, name: String)] {
        controller.enabledSources()
    }

    // MARK: - The engine — internal & testable

    /// The context changed to `newContextID` (an app switch or a within-browser host change). Capture
    /// the *outgoing* context's current source (learn — the only write path), then select the *incoming*
    /// context's remembered source (apply). Internal so tests can drive it directly without a real app
    /// activation or host reader.
    ///
    /// Reading the current source ONCE up front — before we apply — is the crux: at this instant the OS
    /// still reports the outgoing context's source, so learning is deterministic and correctly attributed.
    func handleContextChange(contextID newContextID: String?) {
        // Re-entering the same context is a no-op: never re-apply over an in-place change the user just
        // made within the context (that change is theirs to keep until they leave). A no-op poll tick
        // (host unchanged) lands here too.
        guard newContextID != lastActiveContextID else { return }
        let current = controller.currentSourceID()
        learnOutgoing(current: current)
        // Record what the incoming context settles on, so when we later leave it we can tell whether the
        // user actively changed its language (per-site) versus just passed through at the applied source.
        settledSourceForActiveContext = applyIncoming(contextID: newContextID, current: current)
        lastActiveContextID = newContextID
    }

    /// Remember the outgoing context's source as we leave it.
    ///
    /// - **Per-app** (a bare bundle-id key): last-used-wins, always (design D3) — there are few apps and
    ///   the user expects each to restore whatever it was last on.
    /// - **Per-site** (a `bundleID|host` key): remember the site ONLY when the user *actively changed* its
    ///   language — the source on leaving differs from what we settled on when entering. A site merely
    ///   visited at its applied language is not recorded, so the saved-sites list holds deliberate choices,
    ///   not every site browsed. Changing a site back to the global default removes its entry (it is no
    ///   longer special). Skipped entirely when there is no prior context or the source can't be read.
    private func learnOutgoing(current: InputSourceID?) {
        guard let prev = lastActiveContextID, let current else { return }
        guard ContextKey.isSiteKey(prev) else {
            store.setSource(current, forBundleID: prev)   // per-app: always remember last-used
            return
        }
        // Per-site: only deliberate changes are remembered.
        guard current != settledSourceForActiveContext else { return }   // unchanged this visit → ignore
        if let def = normalizedGlobalDefault(), current == def {
            store.removeSource(forBundleID: prev)   // reverted to the global default → no longer a saved site
        } else {
            store.setSource(current, forBundleID: prev)
        }
    }

    /// Select the incoming context's remembered source (or the global default for an unseen context,
    /// design D7), short-circuiting a redundant select (spec "No redundant switch") and ignoring a nil
    /// context — e.g. a bundle-less surface (design D1). A failed select (since-disabled source) is a
    /// silent best-effort no-op: keep the current source and log only — never an alert (spec "Failure to
    /// select … is silent", design D5 / risk table).
    ///
    /// The context id is passed to `KeyboardLanguagePolicy.activate` as its `bundleID` argument: the
    /// policy is keyed on an opaque string, so a `bundleID|host` context id flows through it unchanged.
    /// Returns the source the context *settles on* after applying: the source we selected, or the
    /// unchanged `current` when there is nothing to apply (no context, unseen with no default) or a select
    /// fails. `handleContextChange` stashes this so a later `learnOutgoing` can detect a deliberate change.
    @discardableResult
    private func applyIncoming(contextID: String?, current: InputSourceID?) -> InputSourceID? {
        guard let contextID else { return current }
        guard let desired = KeyboardLanguagePolicy.activate(bundleID: contextID,
                                                            map: store.map,
                                                            globalDefault: normalizedGlobalDefault())
        else { return current }   // unseen with no default → applied nothing; settles on the current source
        guard desired != current else { return desired }   // redundant skip; already on the desired source
        if controller.select(desired) { return desired }   // applied → settles on the selected source
        NSLog("[ThreeFingerSwitcher] keyboard-language: failed to select \(desired) for \(contextID) (likely disabled); leaving current source.")
        return current   // select failed → settles on the unchanged current source
    }

    /// The configured global default, normalizing an empty string to nil so a blank `AppSettings`
    /// default reads as "unset" (the picker's "None" option persists as the empty string, design D7).
    private func normalizedGlobalDefault() -> InputSourceID? {
        let value = globalDefault()
        return (value?.isEmpty == true) ? nil : value
    }
}
