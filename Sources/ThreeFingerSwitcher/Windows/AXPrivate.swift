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
func bruteForceWindows(pid: pid_t, budgetMs: Double = 100) -> [(CGWindowID, AXUIElement)] {
    guard let create = cgs.createWithRemoteToken else { return [] }
    var results: [(CGWindowID, AXUIElement)] = []
    let deadline = DispatchTime.now() + .milliseconds(Int(budgetMs))
    for axId in 0..<1000 {
        if DispatchTime.now() >= deadline { break }
        let token = remoteToken(pid: pid, id: UInt(axId))
        guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
        let subrole = axString(element, kAXSubroleAttribute as String)
        guard subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String) else { continue }
        if let wid = axWindowID(element) {
            results.append((wid, element))
        }
    }
    return results
}
