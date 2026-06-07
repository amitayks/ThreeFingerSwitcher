import CoreGraphics

/// Read/write display brightness via the private `DisplayServices` framework, resolved crash-safely
/// at first use (same dlsym pattern as `CGSPrivate` / `MissionControl`): if the symbols can't be
/// found the calls return nil/false and the caller falls back to native key-stepping — never a crash,
/// and **no new permission** (DisplayServices needs none, unlike AppleScript/Automation).
///
/// Works on the built-in display (Apple Silicon + Intel). Some external/DDC displays don't support
/// it; `set` returns false there so the caller can step instead.
enum DisplayBrightness {
    private typealias FnGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnSet = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    private static let getFn: FnGet? = handle
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
        .map { unsafeBitCast($0, to: FnGet.self) }

    private static let setFn: FnSet? = handle
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
        .map { unsafeBitCast($0, to: FnSet.self) }

    /// Current brightness 0…1, or nil if unavailable for this display.
    static func get(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var level: Float = 0
        return getFn(display, &level) == 0 ? level : nil
    }

    /// Set brightness 0…1. Returns false if unsupported (caller falls back to stepping).
    @discardableResult
    static func set(_ display: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setFn else { return false }
        return setFn(display, min(max(value, 0), 1)) == 0
    }
}
