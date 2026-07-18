import Foundation
import AppKit
import ApplicationServices

/// The live `AXUIElement` boundary (`add-voice-computer-use-agent`, design D5): reads a window's
/// accessibility tree into the pure `AXNodeData` shape and resolves element paths back to live
/// elements at act time. Every OS failure is mapped to `AXActionError` HERE — nothing above this
/// file sees a raw `AXError`. Reads run off the main thread (`Task.detached`) with a per-element
/// messaging timeout so a beach-balling target app never freezes a turn (the loop's step timeout is
/// the outer bound).
public final class AXWindowReader: Sendable {

    /// Per-element AX messaging timeout (seconds) — a hung AX server fails fast into
    /// `appNotResponding` instead of blocking the walk.
    private static let messagingTimeout: Float = 2.0

    public init() {}

    /// Read the target window's tree. `titleHint` picks among the app's windows (fuzzy contains);
    /// nil → the app's focused/first window.
    public func readWindow(pid: pid_t, titleHint: String?) async throws -> (root: AXNodeData, title: String, appName: String) {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App"
        return try await Task.detached(priority: .userInitiated) {
            guard AXIsProcessTrusted() else { throw AXActionError.notPermitted }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)

            guard let window = try Self.pickWindow(appElement, titleHint: titleHint, appName: appName) else {
                throw AXActionError.windowGone
            }
            let title = Self.stringAttribute(window, kAXTitleAttribute) ?? ""
            let root = try Self.node(from: window, appName: appName, depth: 0)
            return (root, title, appName)
        }.value
    }

    /// Re-resolve an element by its recorded child-index path (act time). Throws `staleElement` when
    /// the walk falls off the tree (the window changed since the snapshot).
    public func resolveElement(pid: pid_t, titleHint: String?, path: [Int]) async throws -> AXUIElement {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "App"
        return try await Task.detached(priority: .userInitiated) {
            guard AXIsProcessTrusted() else { throw AXActionError.notPermitted }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout)
            guard let window = try Self.pickWindow(appElement, titleHint: titleHint, appName: appName) else {
                throw AXActionError.windowGone
            }
            var current = window
            for index in path {
                let children = Self.children(of: current)
                guard index < children.count else { throw AXActionError.staleElement }
                current = children[index]
            }
            return current
        }.value
    }

    // MARK: - Tree walking (background thread)

    private static func pickWindow(_ appElement: AXUIElement, titleHint: String?,
                                   appName: String) throws -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        switch result {
        case .success: break
        case .cannotComplete: throw AXActionError.appNotResponding(appName: appName)
        case .apiDisabled, .notImplemented: throw AXActionError.notPermitted
        default: throw AXActionError.windowGone
        }
        guard let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }
        guard let hint = titleHint?.lowercased(), !hint.isEmpty else {
            // The app's focused window when available, else the first.
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let focusedWindow = focused, CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() {
                return (focusedWindow as! AXUIElement)
            }
            return windows.first
        }
        return windows.first { (stringAttribute($0, kAXTitleAttribute) ?? "").lowercased().contains(hint) }
            ?? windows.first
    }

    private static func node(from element: AXUIElement, appName: String, depth: Int) throws -> AXNodeData {
        // Hard depth cut here mirrors the builder's limit — the builder is the honest reporter; this
        // is just the walk's own runaway guard.
        let role = stringAttribute(element, kAXRoleAttribute) ?? "AXUnknown"
        let label = stringAttribute(element, kAXTitleAttribute)
            ?? stringAttribute(element, kAXDescriptionAttribute)
            ?? stringAttribute(element, "AXLabel")
            ?? ""
        let value = stringAttribute(element, kAXValueAttribute) ?? ""

        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let actionNames = (actions as? [String]) ?? []
        let pressable = actionNames.contains(kAXPressAction as String)

        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)

        var focusableFlag = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &focusableFlag)

        var childNodes: [AXNodeData] = []
        if depth < 20 {
            for child in children(of: element) {
                childNodes.append(try node(from: child, appName: appName, depth: depth + 1))
            }
        }
        return AXNodeData(role: role, label: label, value: value,
                          isPressable: pressable, isSettable: settable.boolValue,
                          isFocusable: focusableFlag.boolValue, children: childNodes)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
