import Foundation
import ObjectiveC

/// Read/write keyboard backlight brightness via the private `CoreBrightness` framework's
/// `KeyboardBrightnessClient`, resolved crash-safely at first use (the `DisplayBrightness` pattern):
/// class or selectors that can't be resolved make the calls return empty/nil/false — never a crash,
/// and **no new permission**. Used by Keep Awake's keyboard-dim session effect; a keyboard that can't
/// be read is simply skipped (the undimmable-display rule).
enum KeyboardBrightness {
    /// The client instance, or nil if CoreBrightness / the class can't be resolved.
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                     RTLD_NOW) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }
        return cls.init()
    }()

    private static let idsSelector = NSSelectorFromString("copyKeyboardBacklightIDs")
    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

    /// Resolve a selector on the client to a C function pointer, or nil if unsupported.
    private static func imp(_ selector: Selector) -> IMP? {
        guard let client, client.responds(to: selector),
              let cls = object_getClass(client) else { return nil }
        return class_getMethodImplementation(cls, selector)
    }

    /// The IDs of every backlight-controllable keyboard (empty if unavailable).
    static func keyboardIDs() -> [UInt64] {
        guard let client, let fn = imp(idsSelector) else { return [] }
        typealias Fn = @convention(c) (NSObject, Selector) -> Unmanaged<NSArray>?
        // `copy…` returns +1; takeRetainedValue balances it.
        guard let array = unsafeBitCast(fn, to: Fn.self)(client, idsSelector)?
            .takeRetainedValue() else { return [] }
        return array.compactMap { ($0 as? NSNumber)?.uint64Value }
    }

    /// Current backlight level 0…1 for a keyboard, or nil if unavailable.
    static func get(_ keyboard: UInt64) -> Float? {
        guard let client, let fn = imp(getSelector) else { return nil }
        typealias Fn = @convention(c) (NSObject, Selector, UInt64) -> Float
        return unsafeBitCast(fn, to: Fn.self)(client, getSelector, keyboard)
    }

    /// Set the backlight level 0…1. Returns false if unavailable.
    @discardableResult
    static func set(_ keyboard: UInt64, _ value: Float) -> Bool {
        guard let client, let fn = imp(setSelector) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector, Float, UInt64) -> Bool
        return unsafeBitCast(fn, to: Fn.self)(client, setSelector, min(max(value, 0), 1), keyboard)
    }
}
