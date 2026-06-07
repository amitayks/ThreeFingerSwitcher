import AppKit
import ApplicationServices
import CoreAudio
import AudioToolbox

/// Executes a fired `LaunchItem`. Dispatch is split so the *decision* logic (strategy resolution,
/// preset flattening, the new-window menu-title candidates) is pure and unit-testable, while the
/// *effect* logic (NSWorkspace / Accessibility / window placement) is thin and verified on-device.
///
/// "Always a new window" is a strategy ladder (see `AppStrategy`): the smart default presses the
/// app's own `File ▸ New Window` menu item via Accessibility for multi-window apps. For single-window
/// apps the window genuinely can't be moved to the user (macOS blocks moving a foreign window across
/// Spaces without SIP disabled — verified on-device), so `.smart` falls back to a deliberate "go to
/// the window" (switch to its Space and focus it); a per-item `.quitAndReopenHere` can instead quit
/// and relaunch so a fresh window opens here. Nothing ever teleports the user unexpectedly.
@MainActor
final class LaunchService {
    /// Reads the current favorites tree (needed to resolve preset references at fire time).
    private let favoritesProvider: () -> Favorites
    private let mover: WindowRelocating
    /// Switch to an off-Space window and focus it (wired to `WindowService.raise`). Returns false if
    /// no window for the pid could be resolved. Injected so `LaunchService` stays decoupled/testable.
    private let goToWindow: (pid_t) -> Bool
    /// The app whose window a `.action(.closeFrontWindow)` targets — captured when the launcher opens
    /// (the overlay is non-activating, so this is the app the user was actually looking at).
    private let frontAppProvider: () -> NSRunningApplication?
    /// Called right after a Space-switch shortcut (⌃→ / ⌃←) is synthesized. Wired to focus the front
    /// window of the destination Space once the switch settles — macOS leaves it visually front but
    /// not key, exactly like the native shortcut. No-op by default / in tests.
    private let onSpaceSwitch: () -> Void

    init(favoritesProvider: @escaping () -> Favorites,
         mover: WindowRelocating? = nil,
         goToWindow: @escaping (pid_t) -> Bool = { _ in false },
         frontAppProvider: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         onSpaceSwitch: @escaping () -> Void = {}) {
        self.favoritesProvider = favoritesProvider
        self.mover = mover ?? NullWindowMover()
        self.goToWindow = goToWindow
        self.frontAppProvider = frontAppProvider
        self.onSpaceSwitch = onSpaceSwitch
    }

    // MARK: - Fire

    /// Fire an item that lives in `band` (the band supplies the inherited default app strategy).
    func fire(_ item: LaunchItem, inBand band: ContextBand) {
        switch item.kind {
        case .app:
            fireApp(item, strategy: Self.resolvedStrategy(for: item, bandDefault: band.defaultAppStrategy) ?? .smart)
        case .path(let url):
            NSWorkspace.shared.open(url)
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .shortcut(let name):
            runShortcut(named: name, title: item.title)
        case .script(let body):
            runScript(body, title: item.title)
        case .action(let action, let adjustment):
            perform(action, adjustment: adjustment)
        case .preset:
            firePreset(item, inBand: band)
        }
    }

    // MARK: - Built-in actions

    /// Perform a built-in `SystemAction` natively (AX / NSWorkspace / synthesized keys), no subprocess
    /// for the window/app paths and no new permission. Every "front" action targets the app captured
    /// when the launcher opened (`frontAppProvider`).
    private func perform(_ action: SystemAction, adjustment: ValueAdjustment? = nil) {
        switch action {
        // Window
        case .minimizeWindow:
            if let w = frontWindow() { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        case .toggleFullScreen:    toggleFullScreen()
        case .zoomWindow:
            if let w = frontWindow(), let b = axElement(w, kAXZoomButtonAttribute) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
        case .maximizeWindow:      tile(.maximize)
        case .centerWindow:        centerWindow()
        case .tileLeftHalf:        tile(.leftHalf)
        case .tileRightHalf:       tile(.rightHalf)
        case .tileTopHalf:         tile(.topHalf)
        case .tileBottomHalf:      tile(.bottomHalf)
        case .tileTopLeft:         tile(.topLeft)
        case .tileTopRight:        tile(.topRight)
        case .tileBottomLeft:      tile(.bottomLeft)
        case .tileBottomRight:     tile(.bottomRight)
        case .closeFrontWindow:    closeFrontWindow()
        case .closeAllWindows:     closeAllWindows()
        // App
        case .newWindow:           if let app = frontApp() { makeNewWindow(for: app) }
        case .hideFrontApp:        frontApp()?.hide()
        case .hideOtherApps:       hideOthers()
        case .quitFrontApp:        frontApp()?.terminate()
        case .forceQuitFrontApp:   frontApp()?.forceTerminate()
        // System
        case .missionControl:      MissionControl.showMissionControl()
        case .appExpose:           MissionControl.showAppExpose()
        case .showDesktop:         MissionControl.showDesktop()
        // Arrow-key system shortcuts must mimic a REAL arrow press to match macOS's default
        // Move-left/right-a-space hotkey. On macOS the arrow keys are function keys, so a genuine
        // arrow event carries BOTH the numeric-pad flag and the secondary-Fn flag in addition to the
        // modifier. A synthetic arrow missing either is dropped silently (verified: ⌃-only and
        // ⌃+numpad both did nothing) — unlike non-arrow shortcuts (e.g. the screenshots above), which
        // need none of this. Keep them in sync via `spaceSwitchFlags`.
        case .nextSpace:           postKey(0x7C, flags: Self.spaceSwitchFlags, toPid: nil); onSpaceSwitch()   // ⌃→
        case .previousSpace:       postKey(0x7B, flags: Self.spaceSwitchFlags, toPid: nil); onSpaceSwitch()   // ⌃←
        case .lockScreen:          postKey(0x0C, flags: [.maskControl, .maskCommand], toPid: nil) // Ctrl-⌘-Q
        case .screenSaver:         startScreenSaver()
        case .sleepDisplay:        runDetached("/usr/bin/pmset", ["displaysleepnow"])
        case .emptyTrash:          emptyTrash()
        case .screenshotSelection: postKey(0x15, flags: [.maskShift, .maskCommand], toPid: nil) // ⇧⌘4
        case .screenshotFullScreen:postKey(0x14, flags: [.maskShift, .maskCommand], toPid: nil) // ⇧⌘3
        case .screenshotTools:     postKey(0x17, flags: [.maskShift, .maskCommand], toPid: nil) // ⇧⌘5
        // Media & display (system-defined keys)
        case .playPause:           postMediaKey(16)
        case .nextTrack:           postMediaKey(17)
        case .previousTrack:       postMediaKey(18)
        case .volumeUp:            adjustVolume(up: true, adjustment)
        case .volumeDown:          adjustVolume(up: false, adjustment)
        case .mute:                postMediaKey(7)
        case .brightnessUp:        adjustBrightness(up: true, adjustment)
        case .brightnessDown:      adjustBrightness(up: false, adjustment)
        }
    }

    // The app captured when the launcher opened (never our own process), and its front window.
    private func frontApp() -> NSRunningApplication? {
        let app = frontAppProvider()
        return (app?.processIdentifier == getpid()) ? nil : app
    }

    private func frontWindow() -> AXUIElement? {
        guard let app = frontApp() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        return axElement(appEl, kAXFocusedWindowAttribute) ?? axElement(appEl, kAXMainWindowAttribute)
    }

    /// Close the front window: press its AX close button, falling back to a synthesized ⌘W.
    private func closeFrontWindow() {
        guard let app = frontApp() else { return }
        guard let window = frontWindow() else { postKey(0x0D, flags: .maskCommand, toPid: app.processIdentifier); return }
        if let closeButton = axElement(window, kAXCloseButtonAttribute),
           AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success { return }
        postKey(0x0D, flags: .maskCommand, toPid: app.processIdentifier)
    }

    private func closeAllWindows() {
        guard let app = frontApp() else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = axCopy(appEl, kAXWindowsAttribute) as? [AXUIElement] else { return }
        for w in windows {
            if let b = axElement(w, kAXCloseButtonAttribute) { AXUIElementPerformAction(b, kAXPressAction as CFString) }
        }
    }

    private func toggleFullScreen() {
        guard let app = frontApp(), let win = frontWindow() else { return }
        let isFull = axBool(win, "AXFullScreen")
        let err = AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (isFull ? kCFBooleanFalse : kCFBooleanTrue))
        if err != .success { postKey(0x03, flags: [.maskControl, .maskCommand], toPid: app.processIdentifier) } // Ctrl-⌘-F
    }

    private func hideOthers() {
        let front = frontApp()
        let me = getpid()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me && app.processIdentifier != front?.processIdentifier {
            app.hide()
        }
        front?.activate()
    }

    private func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    private func emptyTrash() {
        let fm = FileManager.default
        guard let trash = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
              let items = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    private func runDetached(_ executable: String, _ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
            try? p.run()
        }
    }

    // MARK: Window geometry (AX)

    private enum Tile { case maximize, leftHalf, rightHalf, topHalf, bottomHalf, topLeft, topRight, bottomLeft, bottomRight }

    private func tile(_ t: Tile) {
        guard let win = frontWindow() else { return }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        guard vf.width > 0 else { return }
        let x = vf.minX, y = vf.minY, w = vf.width, h = vf.height
        let rect: CGRect
        switch t {
        case .maximize:    rect = vf
        case .leftHalf:    rect = CGRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf:   rect = CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topHalf:     rect = CGRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .bottomHalf:  rect = CGRect(x: x, y: y, width: w, height: h / 2)
        case .topLeft:     rect = CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .topRight:    rect = CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomLeft:  rect = CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .bottomRight: rect = CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        }
        setAXFrame(win, rect)
    }

    private func centerWindow() {
        guard let win = frontWindow() else { return }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let size = axSize(win)
        setAXFrame(win, CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                               width: size.width, height: size.height))
    }

    /// Set a window's frame from an `NSScreen` (bottom-left) rect, converting to AX (top-left, y-down,
    /// measured from the primary display's top). Position is re-asserted after the resize (apps clamp).
    private func setAXFrame(_ win: AXUIElement, _ ns: CGRect) {
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? ns.height
        var origin = CGPoint(x: ns.minX, y: primaryH - ns.minY - ns.height)
        var size = ns.size
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size)    { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s) }
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
    }

    private func axSize(_ win: AXUIElement) -> CGSize {
        var size = CGSize.zero
        if let v = axCopy(win, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &size)
        }
        return size
    }

    /// Copy an AX attribute that is itself an AXUIElement (window, button), or nil.
    private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: Key / media synthesis

    /// Post a keystroke: to a specific process (`pid`) or, when `pid` is nil, system-wide via the HID
    /// event tap (for OS shortcuts like screenshots / Space switch / lock). Requires Accessibility.
    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t?) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        if let pid { down.postToPid(pid); up.postToPid(pid) }
        else { down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap) }
    }

    /// Post a system-defined media/hardware key (play, next, volume, brightness…) via NX key codes.
    private func postMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(isDown ? 0xA00 : 0xB00))
            let data1 = Int((key << 16) | ((isDown ? 0xA : 0xB) << 8))
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 8, data1: data1, data2: -1) else { continue }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Volume / brightness level control (no new permission)

    /// Pure target-level math (unit-tested): `current` and `amount` are 0…1; the result is clamped to
    /// 0…1. Absolute sets the level outright (direction ignored); relative steps by ±amount.
    nonisolated static func targetLevel(current: Double, up: Bool,
                                        mode: ValueAdjustment.Mode, amount: Double) -> Double {
        let a = min(max(amount, 0), 1)
        switch mode {
        case .absolute: return a
        case .relative: return min(max(current + (up ? a : -a), 0), 1)
        }
    }

    /// Number of native key presses that approximate a percentage change (the OS step is ~6.25%).
    /// Used only as the fallback when a level can't be read/set.
    nonisolated static func stepCount(forPercent percent: Double) -> Int {
        max(1, Int((percent / 6.25).rounded()))
    }

    /// Volume: with no adjustment, the native step (today's behavior). Otherwise set an absolute /
    /// relative level via CoreAudio; if the level can't be read, fall back to native stepping.
    private func adjustVolume(up: Bool, _ adjustment: ValueAdjustment?) {
        guard let adj = adjustment else { postMediaKey(up ? 0 : 1); return }
        guard let device = Self.defaultOutputDevice(), let current = Self.deviceVolume(device) else {
            stepKey(up ? 0 : 1, times: Self.stepCount(forPercent: adj.percent)); return
        }
        let target = Self.targetLevel(current: Double(current), up: up, mode: adj.mode, amount: adj.percent / 100)
        Self.setDeviceVolume(device, Float(target))
    }

    /// Brightness: with no adjustment, the native step. Otherwise set an absolute / relative level via
    /// the private DisplayServices on the main display; fall back to native stepping if it's unavailable.
    private func adjustBrightness(up: Bool, _ adjustment: ValueAdjustment?) {
        guard let adj = adjustment else { postMediaKey(up ? 2 : 3); return }
        let display = CGMainDisplayID()
        guard let current = DisplayBrightness.get(display) else {
            stepKey(up ? 2 : 3, times: Self.stepCount(forPercent: adj.percent)); return
        }
        let target = Self.targetLevel(current: Double(current), up: up, mode: adj.mode, amount: adj.percent / 100)
        if !DisplayBrightness.set(display, Float(target)) {
            stepKey(up ? 2 : 3, times: Self.stepCount(forPercent: adj.percent))
        }
    }

    private func stepKey(_ key: Int32, times: Int) {
        for _ in 0..<max(1, times) { postMediaKey(key) }
    }

    // MARK: CoreAudio (default output device volume)

    private static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return (err == noErr && id != 0) ? id : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceVolume(_ device: AudioObjectID) -> Float? {
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = volumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr ? vol : nil
    }

    private static func setDeviceVolume(_ device: AudioObjectID, _ value: Float) {
        var v = min(max(value, 0), 1)
        var addr = volumeAddress()
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    /// Fire each leaf item of a preset in order, re-dispatching through `fire` so nested kinds use
    /// the same paths. Reports overall success/failure via a notification.
    private func firePreset(_ preset: LaunchItem, inBand band: ContextBand) {
        let favorites = favoritesProvider()
        let leaves = Self.presetFireOrder(preset, in: favorites)
        for leaf in leaves {
            // A leaf keeps its home band's strategy default; we approximate with the preset's band.
            fire(leaf, inBand: bandFor(leaf, in: favorites) ?? band)
        }
        notify(title: preset.title, body: "Ran \(leaves.count) step\(leaves.count == 1 ? "" : "s").", success: true)
    }

    // MARK: - App firing

    private func fireApp(_ item: LaunchItem, strategy: AppStrategy) {
        guard case let .app(bundleURL, _) = item.kind else { return }
        let running = runningInstance(forBundleURL: bundleURL)

        // Not running: launching it opens the first window on the current Space.
        guard let app = running else {
            launch(bundleURL: bundleURL, newInstance: strategy == .newInstance)
            return
        }

        switch strategy {
        case .newInstance:
            launch(bundleURL: bundleURL, newInstance: true)
        case .alwaysNewWindow:
            makeNewWindow(for: app)
        case .bringExistingHere:
            bringExistingHere(app, bundleURL: bundleURL)
        case .quitAndReopenHere:
            quitAndReopenHere(app, bundleURL: bundleURL)
        case .smart:
            if hasNewWindowMenuItem(pid: app.processIdentifier) {
                makeNewWindow(for: app)
            } else {
                bringExistingHere(app, bundleURL: bundleURL)
            }
        }
    }

    /// Create a new window by pressing the app's own File ▸ New Window menu item (capability-correct,
    /// lands on the current Space), falling back to a synthesized ⌘N if the item can't be pressed.
    private func makeNewWindow(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        // Do NOT activate first. Activating fronts the app's existing window and, if it lives on
        // another Space, teleports the user there before the new window even exists. Triggering the
        // new window while we stay put makes it appear on the CURRENT Space (AX menu-press and ⌘N
        // both work against a background app).
        if !pressNewWindowMenuItem(pid: pid) {
            synthesizeCommandN(pid: pid)
        }
        // The new window is being created on the current Space; bring the app forward to it once it
        // exists. Deferred so we never activate while the only window is still off-Space.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            app.activate(options: [])
            self?.raiseFrontWindow(pid: pid)
        }
    }

    /// Focus a single-window app's existing window. If a window is already on the current Space we
    /// focus it locally (no teleport). If it lives only off-Space, macOS won't let an unprivileged app
    /// move it here, so we deliberately *go to it* — switch to its Space and focus it, exactly like the
    /// window switcher. If the running app has no windows anywhere, we reopen it (same as the not-running
    /// path) so a fresh window appears on the current Space. (A per-item `.quitAndReopenHere` is the
    /// opt-in for users who'd rather reopen a fresh window on the current Space instead of switching.)
    private func bringExistingHere(_ app: NSRunningApplication, bundleURL: URL) {
        let pid = app.processIdentifier
        switch mover.relocate(pid: pid) {
        case .broughtHere:
            app.activate(options: [])
            raiseFrontWindow(pid: pid)
        case .noWindows:
            // Running but windowless. `activate()` only fronts the process — it does NOT recreate a
            // window; only NSWorkspace.openApplication / a Dock click sends the reopen event. Most apps
            // make a window from reopen, but some (notably Mac Catalyst apps like Shortcuts) ignore it
            // while fully windowless, so escalate non-destructively. No off-Space window ⇒ no teleport.
            reopenWindowlessApp(app, bundleURL: bundleURL)
        case .failed:
            // Window exists only off-Space; moving a foreign window across Spaces is blocked by macOS.
            // Go to the window (deliberate Space switch + focus). Last resort if it can't be resolved:
            // a plain activate.
            if !goToWindow(pid) { app.activate(options: []) }
        }
    }

    /// Give a running-but-windowless app a window on the current Space without destroying its state.
    /// 1) Reopen via the workspace (Dock-click equivalent) so the app's reopen handler makes a window —
    ///    this is enough for most apps (Xcode, Safari, Finder, Preview…). 2) Some apps (e.g. Mac
    /// Catalyst apps like Shortcuts) ignore reopen while fully windowless, so if no window has appeared
    /// shortly after, escalate to the app's own new-window command (File ▸ New Window, else ⌘N). The
    /// delay both lets a working reopen land first (so we don't double-open) and gives the menu time to
    /// become the active one after the reopen activates the app. An app that responds to neither needs
    /// the explicit `.quitAndReopenHere` strategy.
    private func reopenWindowlessApp(_ app: NSRunningApplication, bundleURL: URL) {
        launch(bundleURL: bundleURL, newInstance: false)
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.windowCount(pid: pid) == 0 else { return }
            self.makeNewWindow(for: app)
        }
    }

    /// Number of the app's AX windows (across all Spaces) — used to tell whether a reopen actually
    /// produced a window before escalating to a new-window command.
    private func windowCount(pid: pid_t) -> Int {
        let appEl = AXUIElementCreateApplication(pid)
        return (axCopy(appEl, kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? 0
    }

    /// Quit the app and relaunch it so a fresh window opens on the CURRENT Space. Destructive (loses
    /// unsaved state) — gated behind the explicit per-item `.quitAndReopenHere`; `.smart` never picks it.
    private func quitAndReopenHere(_ app: NSRunningApplication, bundleURL: URL) {
        app.terminate()   // graceful: the app may save / show a "Save changes?" prompt before quitting
        relaunchWhenTerminated(app, bundleURL: bundleURL, attempt: 0)
    }

    /// Poll for the app to finish quitting, then relaunch (a fresh window opens on the current Space).
    /// Bounded so an app that declines to quit (e.g. a blocking save dialog) doesn't loop forever.
    private func relaunchWhenTerminated(_ app: NSRunningApplication, bundleURL: URL, attempt: Int) {
        if app.isTerminated {
            launch(bundleURL: bundleURL, newInstance: false)
            return
        }
        guard attempt < 40 else { return }   // ~4s; the app didn't quit, leave it as-is
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.relaunchWhenTerminated(app, bundleURL: bundleURL, attempt: attempt + 1)
        }
    }

    /// Raise the app's focused/main window so the brought-here window is frontmost on this Space.
    private func raiseFrontWindow(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] as [CFString] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, attr, &value) == .success,
               let win = value, CFGetTypeID(win) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(win as! AXUIElement, kAXRaiseAction as CFString)
                return
            }
        }
    }

    // MARK: - Launch / shortcut / script effects

    private func launch(bundleURL: URL, newInstance: Bool) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = newInstance
        config.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { [weak self] _, error in
            if let error { Task { @MainActor in self?.notify(title: bundleURL.lastPathComponent,
                                                             body: error.localizedDescription, success: false) } }
        }
    }

    private func runShortcut(named name: String, title: String) {
        run(executable: "/usr/bin/shortcuts", args: ["run", name], title: title)
    }

    private func runScript(_ body: ScriptBody, title: String) {
        switch body {
        case .shell(let code):
            run(executable: "/bin/zsh", args: ["-c", code], title: title)
        case .appleScript(let code):
            run(executable: "/usr/bin/osascript", args: ["-e", code], title: title)
        case .file(let url):
            // .scpt → osascript; otherwise execute directly (respecting its shebang / +x bit).
            if url.pathExtension.lowercased() == "scpt" {
                run(executable: "/usr/bin/osascript", args: [url.path], title: title)
            } else {
                run(executable: url.path, args: [], title: title)
            }
        }
    }

    /// Run a process off the main thread and report success/failure when it exits.
    private func run(executable: String, args: [String], title: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            var ok = false
            var message = ""
            do {
                try process.run()
                process.waitUntilExit()
                ok = process.terminationStatus == 0
                if !ok { message = "Exited with status \(process.terminationStatus)." }
            } catch {
                message = error.localizedDescription
            }
            Task { @MainActor in self?.notify(title: title, body: ok ? "Done." : message, success: ok) }
        }
    }

    // MARK: - Accessibility: menu-bar new-window

    /// True when the app exposes a File-menu "New Window"/"New" item (⇒ multi-window-capable).
    func hasNewWindowMenuItem(pid: pid_t) -> Bool { findNewWindowItem(pid: pid) != nil }

    /// Press the app's File ▸ New Window item. Returns false if it couldn't be located/performed.
    @discardableResult
    private func pressNewWindowMenuItem(pid: pid_t) -> Bool {
        guard let item = findNewWindowItem(pid: pid) else { return false }
        // A submenu parent (e.g. Terminal's "New Window" → profile list) only OPENS the submenu when
        // pressed — it never creates a window, yet the press "succeeds", which is why Terminal used to
        // just flash its menu. Descend and press the first real entry (a concrete profile) instead;
        // for that case ⌘N is the makeNewWindow fallback if this can't find a pressable leaf.
        if let submenu = axChildren(item)?.first, let leaves = axChildren(submenu) {
            guard let leaf = leaves.first(where: { axString($0, kAXTitleAttribute as String)?.isEmpty == false }) else {
                return false
            }
            return AXUIElementPerformAction(leaf, kAXPressAction as CFString) == .success
        }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Walk the app's menu bar for a File-menu item whose title matches a new-window candidate.
    private func findNewWindowItem(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        guard let menuBar = axCopy(appEl, kAXMenuBarAttribute as String),
              let topItems = axChildren(menuBar as! AXUIElement) else { return nil }
        for top in topItems {
            // The File menu's single child is the AXMenu holding the items.
            guard let submenus = axChildren(top), let menu = submenus.first,
                  let items = axChildren(menu) else { continue }
            for item in items {
                guard let title = axString(item, kAXTitleAttribute as String) else { continue }
                if Self.newWindowMenuTitles.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) {
                    return item
                }
            }
        }
        return nil
    }

    private func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
        axCopy(element, kAXChildrenAttribute as String) as? [AXUIElement]
    }

    /// Post ⌘N to a specific process as a fallback when no menu item is found.
    private func synthesizeCommandN(pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        let n: CGKeyCode = 0x2D
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: n, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: n, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
    }

    // MARK: - Helpers

    private func runningInstance(forBundleURL url: URL) -> NSRunningApplication? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
            // Fall back to matching by bundle URL when the identifier can't be read.
            return NSWorkspace.shared.runningApplications.first { $0.bundleURL == url }
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func bandFor(_ item: LaunchItem, in favorites: Favorites) -> ContextBand? {
        favorites.bands.first { band in band.items.contains { $0.id == item.id } }
    }

    private func notify(title: String, body: String, success: Bool) {
        // Lightweight user feedback for consequential kinds. NSUserNotification is deprecated but
        // dependency-free; can be swapped for UNUserNotificationCenter later.
        let n = NSUserNotification()
        n.title = success ? title : "\(title) failed"
        n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }

    // MARK: - Pure decision logic (unit-tested; no system access)

    /// Resolve the effective app strategy: an `.app` item's own override, else the band default.
    /// Non-app kinds have no strategy (returns nil).
    nonisolated static func resolvedStrategy(for item: LaunchItem, bandDefault: AppStrategy) -> AppStrategy? {
        if case let .app(_, strategy) = item.kind { return strategy ?? bandDefault }
        return nil
    }

    /// Flatten a preset into the ordered list of leaf (non-preset) items it will fire, expanding
    /// nested presets depth-first and skipping cycles / already-expanded presets.
    nonisolated static func presetFireOrder(_ preset: LaunchItem, in favorites: Favorites) -> [LaunchItem] {
        var out: [LaunchItem] = []
        var expanding: Set<UUID> = []
        func expand(_ item: LaunchItem) {
            switch item.kind {
            case .preset(let ids):
                guard !expanding.contains(item.id) else { return }   // cycle / re-entry guard
                expanding.insert(item.id)
                for id in ids {
                    if let child = favorites.item(withID: id) { expand(child) }
                }
                expanding.remove(item.id)
            default:
                out.append(item)
            }
        }
        expand(preset)
        return out
    }

    /// Ordered candidate titles for the app's "new window" menu item (first match wins).
    nonisolated static let newWindowMenuTitles = ["New Window", "New OS Window", "New", "New Document"]

    /// Flags for the synthesized ⌃→ / ⌃← Space-switch shortcut. Mimics a real arrow press (control +
    /// numeric-pad + secondary-Fn) so macOS's default Space hotkey matches it; a partial flag set is
    /// silently ignored for arrow keys.
    nonisolated static let spaceSwitchFlags: CGEventFlags = [.maskControl, .maskNumericPad, .maskSecondaryFn]
}

/// Outcome of trying to bring an app's window(s) to the current Space — richer than a Bool so the
/// caller can avoid the teleport: it must NOT activate the app when a window exists only off-Space.
enum RelocateResult {
    /// A window of the app is on the current Space now (moved here, or already here). Safe to activate.
    case broughtHere
    /// The app has no movable window anywhere. Activating it reopens a window here (no teleport).
    case noWindows
    /// Window(s) exist only off-Space and the move could not be confirmed. Activating WOULD teleport.
    case failed
}

/// Abstraction over the teleport-free window move so `LaunchService` stays testable. The real
/// implementation (`SpaceWindowMover`) moves the windows via SkyLight and verifies the move landed
/// before reporting `.broughtHere`, so the caller only activates when it won't switch Spaces.
@MainActor
protocol WindowRelocating {
    func relocate(pid: pid_t) -> RelocateResult
}

/// Default mover used when no real one is injected (e.g. tests): never claims a window is here, so
/// the caller never performs a teleporting activate.
@MainActor
struct NullWindowMover: WindowRelocating {
    func relocate(pid: pid_t) -> RelocateResult { .failed }
}
