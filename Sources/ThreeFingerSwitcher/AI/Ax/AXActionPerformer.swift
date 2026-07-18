import Foundation
import AppKit
import ApplicationServices

/// The read service + act primitives (`add-voice-computer-use-agent`, design D5): `snapshot` reads a
/// window through the boundary reader into the pure builder and registers it with the epoch store;
/// `press`/`typeText` resolve a CONSTRAINED element ID against the current epoch, act, and
/// **verify-after-act** — an act whose expected change is not observable throws `verifyFailed`
/// (never a false "Done"). All OS failures cross as `AXActionError`.
@MainActor
public final class AXActionPerformer {

    /// The verification outcome carried in a step summary.
    public struct Verification: Equatable, Sendable {
        public var verified: Bool
        public var detail: String
    }

    private let reader: AXWindowReader
    private let store: AXSnapshotStore
    /// The tagged source for synthetic keystrokes (`AgentActionArbiter.eventSource`). nil = tests /
    /// no-posting environments (the AXValue fast path still works).
    private let eventSource: CGEventSource?

    public init(reader: AXWindowReader, store: AXSnapshotStore, eventSource: CGEventSource?) {
        self.reader = reader
        self.store = store
        self.eventSource = eventSource
    }

    /// Convenience with fresh collaborators (the coordinator passes the arbiter's tagged source).
    public convenience init(eventSource: CGEventSource? = nil) {
        self.init(reader: AXWindowReader(), store: AXSnapshotStore(), eventSource: eventSource)
    }

    public var snapshotStore: AXSnapshotStore { store }

    // MARK: - Read

    /// Read + register a fresh snapshot for the target window (the `read_window` tool's engine).
    public func snapshot(pid: pid_t, titleHint: String?) async throws -> AXWindowSnapshot {
        let (root, title, appName) = try await reader.readWindow(pid: pid, titleHint: titleHint)
        let built = AXSnapshotBuilder.build(pid: pid, appName: appName, title: title,
                                            root: root, epoch: 0)
        let registered = store.register(built)
        // An AX desert is an HONEST failure, not an empty success (spec: "An AX desert is honest").
        if registered.textBlocks.isEmpty && registered.elements.isEmpty {
            throw AXActionError.unreadableWindow(appName: appName)
        }
        return registered
    }

    // MARK: - Acts (constrained IDs + verify-after-act)

    /// Press an enumerated element. Verify: the window's content changed, a new window/sheet
    /// appeared, or the frontmost app changed — SOME observable consequence; none → `verifyFailed`.
    public func press(pid: pid_t, titleHint: String?, elementID: String) async throws -> Verification {
        let ref = try store.resolve(elementID, pid: pid)
        guard ref.isPressable else { throw AXActionError.elementNotActionable(role: ref.role) }
        let preHash = store.current(for: pid)?.contentHash ?? ""
        let preFront = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let element = try await reader.resolveElement(pid: pid, titleHint: titleHint, path: ref.path)
        try await performOffMain(element: element, appPID: pid) { el in
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        }

        // Settle briefly, then re-read: the post-act snapshot ALSO advances the epoch, so pre-act
        // element IDs go stale by construction (the window changed; the model must re-read).
        try? await Task.sleep(nanoseconds: 250_000_000)
        let post = try? await snapshot(pid: pid, titleHint: titleHint)
        let postFront = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if let post, post.contentHash != preHash {
            return Verification(verified: true, detail: "the window updated")
        }
        if postFront != preFront {
            return Verification(verified: true, detail: "focus moved to another app/window")
        }
        throw AXActionError.verifyFailed(expectation: "pressing “\(ref.label.isEmpty ? ref.role : ref.label)” changes the window")
    }

    /// Type into an element (or the window's focused element when `elementID` is nil). Prefers the
    /// `AXValue` fast path for settable fields (verifiable exactly); falls back to tagged synthetic
    /// keystrokes for terminal-like surfaces. `submit` appends Return.
    public func typeText(pid: pid_t, titleHint: String?, elementID: String?,
                         text: String, submit: Bool) async throws -> Verification {
        if let elementID {
            let ref = try store.resolve(elementID, pid: pid)
            let element = try await reader.resolveElement(pid: pid, titleHint: titleHint, path: ref.path)
            // Focus the target first so a keystroke fallback (and the user's mental model) agree
            // about where the text lands.
            _ = try? await performOffMain(element: element, appPID: pid) { el in
                AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            if ref.isSettable {
                let existing = try await currentValue(of: element, appPID: pid) ?? ""
                let newValue = existing + text
                try await performOffMain(element: element, appPID: pid) { el in
                    AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, newValue as CFString)
                }
                let readBack = try await currentValue(of: element, appPID: pid) ?? ""
                guard readBack.contains(text) else {
                    throw AXActionError.verifyFailed(expectation: "the field contains the typed text")
                }
                if submit { postKeystroke(keyCode: 36) }   // Return
                _ = try? await snapshot(pid: pid, titleHint: titleHint)   // advance the epoch honestly
                return Verification(verified: true, detail: "field now contains the text")
            }
        }
        // Keystroke path (no element / not settable): synthetic tagged unicode events.
        guard eventSource != nil else {
            throw AXActionError.elementNotActionable(role: "keyboard")
        }
        let preHash = store.current(for: pid)?.contentHash
        postUnicode(text)
        if submit { postKeystroke(keyCode: 36) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let post = try? await snapshot(pid: pid, titleHint: titleHint)
        if let preHash, let post, post.contentHash == preHash {
            throw AXActionError.verifyFailed(expectation: "typing changes the window content")
        }
        return Verification(verified: true, detail: "typed \(text.count) characters")
    }

    // MARK: - Internals

    /// Run one AX call off-main with the boundary error map.
    @discardableResult
    private func performOffMain(element: AXUIElement, appPID: pid_t,
                                _ call: @escaping @Sendable (AXUIElement) -> AXError) async throws -> AXError {
        let appName = NSRunningApplication(processIdentifier: appPID)?.localizedName ?? "App"
        let result = await Task.detached(priority: .userInitiated) { call(element) }.value
        switch result {
        case .success: return result
        case .cannotComplete: throw AXActionError.appNotResponding(appName: appName)
        case .apiDisabled, .notImplemented: throw AXActionError.notPermitted
        case .invalidUIElement: throw AXActionError.staleElement
        case .actionUnsupported, .attributeUnsupported:
            throw AXActionError.elementNotActionable(role: "element")
        default: throw AXActionError.staleElement
        }
    }

    private func currentValue(of element: AXUIElement, appPID: pid_t) async throws -> String? {
        try await Task.detached(priority: .userInitiated) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }.value
    }

    /// Post `text` as tagged synthetic unicode keyboard events (chunked — CGEvent's unicode payload
    /// is bounded).
    private func postUnicode(_ text: String) {
        guard let source = eventSource else { return }
        for chunk in text.chunked(into: 16) {
            let utf16 = Array(chunk.utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private func postKeystroke(keyCode: CGKeyCode) {
        guard let source = eventSource else { return }
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
