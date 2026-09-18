import ApplicationServices
import CoreGraphics

/// Private Accessibility SPI used by AltTab and similar tools to correlate an AX window
/// element with its CGWindowID (needed to match ScreenCaptureKit windows). Borrowing this
/// technique from AltTab (GPL-3) is the reason this project is GPL-3.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

func axWindowID(_ element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    return _AXUIElementGetWindow(element, &wid) == .success ? wid : nil
}

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    (axCopy(element, attribute) as? Bool) ?? false
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axCopy(element, attribute) as? String
}

/// An `AXUIElement`-valued attribute, type-checked before the cast. `axCopy` returns an untyped
/// `CFTypeRef`, and `as!` on a CF value TRAPS on a type mismatch — nothing stops a misbehaving app's
/// AX server (Electron, Qt, Java, Wine…) from answering a window attribute with a string or number.
/// Every element-valued read must go through here, never `as! AXUIElement`.
func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

/// An `AXValue`-valued attribute (position / size), type-checked — same rationale as `axElement`.
func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
    guard let value = axCopy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    return (value as! AXValue)
}

/// Build the 20-byte remote token AltTab uses with `_AXUIElementCreateWithRemoteToken`:
/// pid (4) + 0 (4) + magic 0x636f636f "coco" (4) + axUiElementId (8).
private func remoteToken(pid: pid_t, id: UInt) -> Data {
    var token = Data(count: 20)
    token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
    token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
    token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
    return token
}

/// Brute-force the AX window elements of a process by remote token. This is the only reliable
/// way to obtain a VALID AXUIElement for a window on another Space (kAXWindowsAttribute can't
/// see off-Space windows). Also reaches windows created before this process launched.
/// Returns (CGWindowID, element) pairs for standard windows / dialogs. Budgeted to avoid stalls.
///
/// The subrole pre-filter mirrors the switcher's `isSwitchable` gate so an off-Space window that
/// WOULD be listed is also acquirable here (and one that wouldn't isn't wasted on): strict mode keeps
/// only `AXStandardWindow` / `AXDialog`; when `includeNonStandard` is set, ANY window-role element
/// counts, so a Qt/panel window with a non-standard or unknown subrole (the Android emulator, Xcode's
/// welcome window) resolves off-Space too. Role (not subrole) is the window discriminator in the
/// relaxed path, so non-window elements the remote-token sweep also resolves are still dropped.
func bruteForceWindows(pid: pid_t, includeNonStandard: Bool = false, budgetMs: Double = 100) -> [(CGWindowID, AXUIElement)] {
    guard let create = cgs.createWithRemoteToken else { return [] }
    var results: [(CGWindowID, AXUIElement)] = []
    let deadline = DispatchTime.now() + .milliseconds(Int(budgetMs))
    for axId in 0..<1000 {
        if DispatchTime.now() >= deadline { break }
        let token = remoteToken(pid: pid, id: UInt(axId))
        guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
        if includeNonStandard {
            guard axString(element, kAXRoleAttribute as String) == (kAXWindowRole as String) else { continue }
        } else {
            let subrole = axString(element, kAXSubroleAttribute as String)
            guard subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String) else { continue }
        }
        if let wid = axWindowID(element) {
            results.append((wid, element))
        }
    }
    return results
}
