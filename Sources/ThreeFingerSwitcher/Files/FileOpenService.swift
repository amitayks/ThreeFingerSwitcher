import Foundation
import Combine

/// One Open-With choice for a file: an `AppCandidate` (its `url` + display `name`) plus whether it is the
/// file's **default** application, so the menu can mark the default.
///
/// `AppCandidate` (defined in `BandsCanvas.swift`) is reused verbatim — it is the Core's existing
/// `{ url, name }` value and already drives the favorites app browser — because it is exactly the shape an
/// Open-With row needs. `AppCandidate` itself carries no default-indication slot (it is a plain installed-app
/// descriptor), so the "default app indicated" the spec requires is added here, alongside it, rather than by
/// widening `AppCandidate`.
struct OpenWithCandidate: Identifiable, Equatable {
    /// The application (its bundle URL and display name).
    let app: AppCandidate
    /// True when this is the file's default application (the one a plain open would launch).
    let isDefault: Bool

    /// Stable identity for the list: the app's path (so re-querying the same associations doesn't strobe).
    var id: String { app.id }

    static func == (lhs: OpenWithCandidate, rhs: OpenWithCandidate) -> Bool {
        lhs.app.url == rhs.app.url && lhs.isDefault == rhs.isDefault
    }
}

/// Opens a highlighted `FileEntry` for real — a file in its default (or a chosen) application, a folder as a
/// Finder window — and enumerates the Open-With candidates for a file. The opened window lands on the
/// **current Space** natively: the open is routed through the `FileWorkspace` seam (whose conformer sets
/// `configuration.activates = true`), NOT through `SpaceWindowMover` (design D9) — so nothing teleports the
/// user to another Space.
///
/// Modeled on `AICommandExecutor`: `@MainActor` + `ObservableObject`, holding the observable `state` a
/// surface (the column navigator's failure row) binds to, so a failed open is **observable, never a silent
/// false success** (spec: "Failures are observable, never silent"). Every workspace/OS error is mapped into
/// the shared `FileActionError` taxonomy at the `FileWorkspace` boundary, so a `.failed` headline is always a
/// clean per-case sentence — never raw error text.
///
/// All opens target the **captured front-app context** — the app the user was looking at when the launcher
/// opened — not whichever app is frontmost at the instant of firing (the overlay is non-activating). That
/// context is injected (`activateFrontAppContext`, run just before the open fires) so the service never
/// reaches into AppKit for `frontmostApplication` itself and stays unit-testable against a stub workspace.
@MainActor
final class FileOpenService: ObservableObject {

    /// The service's observable state — the contract the failure surface binds to. Mirrors the AI canvas's
    /// state shape: an open is in flight (`.opening`), landed (`.opened`), or surfaced a clean bounded
    /// failure (`.failed`); `.idle` is the resting state (no open, or one defused before it fired).
    enum State: Equatable {
        /// Nothing in flight (also where a defused / discarded open leaves the service — opening nothing).
        case idle
        /// A committed open is firing (between commit and the workspace returning).
        case opening
        /// The open actually launched (never reached unless the workspace returned without throwing).
        case opened
        /// A typed failure with a clean, bounded, user-facing `headline` (never raw error text) plus the
        /// opt-in copyable `details` (the raw workspace/OS text captured at the boundary — `nil` when the
        /// headline already says everything), so a surface can offer a "Show details / Copy" disclosure
        /// without ever putting raw text in the headline. The user can retry or discard from this state
        /// (spec: "A failed open surfaces a clean, bounded message").
        case failed(headline: String, details: String?)
    }

    @Published private(set) var state: State = .idle

    /// The system-workspace seam (open / Open-With / app association). Injected so tests drive a stub that
    /// records calls and simulates failures, and so Core stays AppKit-free; production injects
    /// `SystemFileWorkspace` (which wraps `NSWorkspace` and maps errors to `FileActionError` at the boundary).
    private let workspace: FileWorkspace
    /// The captured front-app context: a side effect the service runs **before** firing an open so the open
    /// targets the app the user was looking at, never the frontmost app at fire time. Returns to the resting
    /// app context; no-op by default / in tests. Modeled on `LaunchService`/`SelectionService`'s injected
    /// `frontAppProvider` — kept a bare closure here so the service (and its Core taxonomy) stays AppKit-free.
    private let activateFrontAppContext: () -> Void

    /// The built-in-player routing decision (`media-player` spec: "Media-kind classification routes the
    /// open"): given an entry, returns the `MediaKind` to play in the built-in player, or `nil` to fall
    /// through to the system default app. The controller builds it from `AppSettings` (opt-in on AND the
    /// per-kind default-open enabled); `nil` by default / in tests, so opens behave exactly as before.
    private let mediaPlaybackRoute: (FileEntry) -> MediaKind?
    /// Hand an entry to the built-in player (the controller wires it to `PlayerController.play`). Run via a
    /// defusable `PendingOpen` exactly like a workspace open, so a four-finger discard before the fuse plays
    /// nothing. No-op by default / in tests.
    private let playMedia: (FileEntry, MediaKind) async -> Void

    /// The pending open awaiting its commit/cancel (the defusable held state). Retained so a `cancel()`
    /// (discard) can defuse it before its fuse fires; cleared after it commits, cancels, or its fuse lands.
    private(set) var pendingOpen: PendingOpen?

    init(workspace: FileWorkspace,
         activateFrontAppContext: @escaping () -> Void = {},
         mediaPlaybackRoute: @escaping (FileEntry) -> MediaKind? = { _ in nil },
         playMedia: @escaping (FileEntry, MediaKind) async -> Void = { _, _ in }) {
        self.workspace = workspace
        self.activateFrontAppContext = activateFrontAppContext
        self.mediaPlaybackRoute = mediaPlaybackRoute
        self.playMedia = playMedia
    }

    // MARK: - Open-With enumeration

    /// The applications that can open **this file**, in the system's order, with the file's default
    /// application indicated. Derived on demand from the workspace's association of apps to the file
    /// (`urlsForApplications(toOpen:)`); the default is `urlForApplication(toOpen:)`. Empty when no installed
    /// application handles the file (the caller then has nothing to offer / surfaces "no app").
    ///
    /// Open-With is a **file** action only: a folder's default open is a Finder window, so this returns empty
    /// for a directory entry (the navigator does not offer Open-With for folders).
    func openWithCandidates(for file: FileEntry) -> [OpenWithCandidate] {
        guard !file.isDirectory else { return [] }
        let defaultApp = workspace.urlForApplication(toOpen: file.url)
        return workspace.urlsForApplications(toOpen: file.url).map { appURL in
            OpenWithCandidate(app: AppCandidate(url: appURL),
                              isDefault: appURL == defaultApp)
        }
    }

    /// Surface the "no installed application can open this file" outcome as observable bounded state: an
    /// Open-With with an EMPTY candidate list has nothing to pick, so rather than silently doing nothing the
    /// service transitions to `.failed` carrying the clean `FileActionError.noApplicationForFile` headline
    /// (spec: "Failures are observable, never silent"). Mapped into the taxonomy here, at the service
    /// boundary, so the headline is a clean per-file sentence — never raw error text. The surface (the
    /// navigator's failure row) binds `state`; it is bounded + non-blocking, never an app-modal alert.
    func surfaceNoApplication(for file: FileEntry) {
        state = Self.failure(for: FileActionError.noApplicationForFile(name: file.name), fallbackName: file.name)
    }

    // MARK: - Defusable opens (prepare → commit / cancel)

    /// Prepare a **default** open of `entry` (a file in its default app, a folder as a Finder window) as a
    /// defusable `PendingOpen`: the open does NOT fire here — it fires on the returned pending's `commit()`
    /// (optionally after a short fuse), and a `cancel()` before then opens nothing. A new prepare supersedes
    /// any still-pending one (it is cancelled first), so only one open is ever in flight.
    @discardableResult
    func prepareOpen(_ entry: FileEntry) -> PendingOpen {
        // Built-in-player branch: a playable media file the player should handle plays IN the player
        // instead of launching the system app — but still as a defusable pending (a four-finger discard
        // before the fuse plays nothing). A folder, a non-media file, or the opt-in being off falls
        // straight through to the unchanged default-open path. Open-With (`prepareOpenWith`) is never
        // routed here — it always opens externally.
        if !entry.isDirectory, let kind = mediaPlaybackRoute(entry) {
            return prepare { [weak self] in
                await self?.performPlay(entry, kind: kind)
            }
        }
        return prepare { [weak self] in
            await self?.performOpenDefault(entry)
        }
    }

    /// Prepare an **Open-With** of `file` using the application at `appURL`, as a defusable `PendingOpen`
    /// (same held → commit/cancel lifecycle as `prepareOpen`).
    @discardableResult
    func prepareOpenWith(_ file: FileEntry, appURL: URL) -> PendingOpen {
        prepare { [weak self] in
            await self?.performOpenWith(file, appURL: appURL)
        }
    }

    /// Cancel (defuse) the current pending open, if any: nothing opens, and the service returns to `.idle`.
    /// Safe to call when there is no pending open (a stray discard is a no-op) and **never terminates an
    /// already-running application** — it only defuses a not-yet-fired open (spec: "Defusable open").
    func cancelPending() {
        pendingOpen?.cancel()
    }

    /// Build a `PendingOpen` around `fire` (the deferred open effect), wiring the held → commit/cancel
    /// lifecycle: committing runs the captured-front-app activation, transitions to `.opening`, then runs the
    /// effect; cancelling defuses (opening nothing) and rests at `.idle`. The pending reference is cleared in
    /// both terminal paths so a later discard can't re-fire it.
    private func prepare(_ fire: @escaping () async -> Void) -> PendingOpen {
        pendingOpen?.cancel()   // a new prepare supersedes any still-pending open
        let pending = PendingOpen(
            onCommit: { [weak self] in
                guard let self else { return }
                self.pendingOpen = nil
                // Target the captured front-app context (not the frontmost app at fire time) before opening.
                self.activateFrontAppContext()
                self.state = .opening
                await fire()
            },
            onCancel: { [weak self] in
                guard let self else { return }
                self.pendingOpen = nil
                self.state = .idle   // defused: nothing opened, never kills a running app
            }
        )
        pendingOpen = pending
        state = .idle   // held: visible/resting until the commit (down-swipe) or discard
        return pending
    }

    // MARK: - Open effects (workspace boundary)

    /// Fire a default open of `entry` through the workspace, surfacing the outcome: a clean bounded `.failed`
    /// (its `FileActionError` headline) if the open did not launch, `.opened` only when it actually did. The
    /// workspace already lands the window on the current Space and maps any OS error to `FileActionError`.
    private func performOpenDefault(_ entry: FileEntry) async {
        do {
            try await workspace.open(entry.url)
            state = .opened
        } catch {
            state = Self.failure(for: error, fallbackName: entry.name)
        }
    }

    /// Hand a media file to the built-in player. `prepare`'s commit has already run the captured-front-app
    /// activation and set `.opening`, so this is just the handoff: the player owns its own observable
    /// failure surface (`PlayerTransportModel`), so the open "landed" once the player took over (a player
    /// load failure surfaces on the player, never as a false success here).
    private func performPlay(_ entry: FileEntry, kind: MediaKind) async {
        await playMedia(entry, kind)
        state = .opened
    }

    /// Fire an Open-With of `file` using the app at `appURL` through the workspace, with the same
    /// outcome surfacing as `performOpenDefault`.
    private func performOpenWith(_ file: FileEntry, appURL: URL) async {
        do {
            try await workspace.open(file.url, withApplicationAt: appURL)
            state = .opened
        } catch {
            state = Self.failure(for: error, fallbackName: file.name)
        }
    }

    // MARK: - Messaging

    /// The `.failed` State for an open failure: a clean, user-facing **headline** plus the opt-in copyable
    /// **details** (the raw text, surfaced only behind a "Show details / Copy" disclosure). A `FileActionError`
    /// (mapped at the workspace boundary) is self-describing via `LocalizedError`, so its `errorDescription`
    /// is the headline directly and its `copyableDetails` carries the raw OS/workspace text; any other error
    /// never reaches a headline — it falls back to a clean, file-named sentence with no details (the raw text
    /// is confined to the boundary's logs, never interpolated into the headline — spec: "No raw error text in
    /// user-facing strings").
    private static func failure(for error: Error, fallbackName: String) -> State {
        if let fileError = error as? FileActionError, let description = fileError.errorDescription {
            return .failed(headline: description, details: fileError.copyableDetails)
        }
        // The boundary maps every workspace error into `FileActionError`, so this is a defensive floor: a
        // clean per-file sentence (no details), never a reflected dump of `error`.
        return .failed(headline: FileActionError.openFailed(name: fallbackName, details: nil).errorDescription ?? "",
                       details: nil)
    }
}

/// A held, **defusable** open: the open effect is captured but not yet fired, so a discard issued before it
/// fires opens nothing (spec: "Defusable open"). Modeled on the AI canvas's held → commit/cancel lifecycle
/// (`AICommandExecutor`'s `isCommittable` / `commit` / `cancel`): a four-finger DOWN swipe `commit()`s it, a
/// horizontal discard `cancel()`s it, and a stray re-lift is a no-op (the firing lift already resolved it).
///
/// `commit()` optionally arms a short **fuse** (a retained `Task` you can cancel) before the effect fires, so
/// a discard within the fuse window still defuses it; once the effect has actually run there is nothing to
/// defuse — and defusing **never terminates an already-running application**, it only prevents a not-yet-fired
/// open. The pending is **one-shot**: after it commits or cancels, every later `commit()`/`cancel()` is a
/// no-op, so a stray re-lift cannot double-open or cancel a window that is already up.
@MainActor
final class PendingOpen {
    /// The resolution lifecycle. `held` is the live state a down-swipe commits / a horizontal swipe cancels;
    /// `fusing` is committed-but-not-yet-fired (the fuse is counting down and can still be defused by a
    /// discard); `committed` / `cancelled` are terminal. Mirrors the canvas's "resolve once" rule.
    private enum Phase { case held, fusing, committed, cancelled }
    private var phase: Phase = .held

    /// Whether a DOWN-swipe commit would still COMMIT (the open is held and not yet resolved). Mirrors
    /// `AICommandExecutor.State.isCommittable`: false once committed/cancelled (or while a fuse is mid-flight),
    /// which is what makes a stray re-lift a no-op.
    var isCommittable: Bool { phase == .held }

    /// Whether the open can still be **defused** by a discard: while held, or while its fuse is counting down
    /// (committed but not yet fired). Once the effect has actually fired there is nothing left to defuse.
    var isDefusable: Bool { phase == .held || phase == .fusing }

    /// Fired (once) when the open commits — runs the actual workspace open via the service.
    private let onCommit: () async -> Void
    /// Fired (once) when the open is cancelled/defused — resets the service, opening nothing.
    private let onCancel: () -> Void
    /// The retained fuse, when `commit(afterFuse:)` armed one. Cancelling it (via `cancel()`) before it fires
    /// defuses the open. `nil` when the commit fired the effect immediately.
    private var fuse: Task<Void, Never>?

    init(onCommit: @escaping () async -> Void, onCancel: @escaping () -> Void) {
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    /// Commit the open: fire it now (or, if `afterFuse` > 0, after that delay via a retained, cancellable
    /// `Task` — so a discard within the window still defuses it). One-shot: a second `commit()` (or a
    /// `commit()` after a `cancel()`) is ignored, so a stray re-lift never double-opens.
    func commit(afterFuse fuse: Duration = .zero) {
        guard phase == .held else { return }
        guard fuse > .zero else {
            phase = .committed
            Task { await onCommit() }
            return
        }
        // Armed but not fired: stays defusable (a discard within the window cancels the fuse → opens nothing).
        phase = .fusing
        self.fuse = Task { [weak self] in
            try? await Task.sleep(for: fuse)
            guard let self, !Task.isCancelled, self.phase == .fusing else { return }
            self.phase = .committed
            await self.onCommit()
        }
    }

    /// Cancel (defuse) the open: cancel any armed fuse and open nothing. One-shot and idempotent — a
    /// discard after the open already fired (or was already cancelled) is a no-op, and it **never** terminates
    /// an already-running app (there is no terminate path here at all — only a not-yet-fired open is prevented).
    func cancel() {
        guard isDefusable else { return }   // a discard after the open already fired is a no-op
        phase = .cancelled
        fuse?.cancel()
        fuse = nil
        onCancel()
    }
}
