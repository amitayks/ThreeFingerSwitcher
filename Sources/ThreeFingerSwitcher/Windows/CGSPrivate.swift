import Foundation
import CoreGraphics
import ApplicationServices
import Carbon

// Private CoreGraphicsServices (CGS) / SkyLight (SLS) bridge.
//
// CRITICAL crash-safety: a `@_silgen_name` reference to a symbol absent from every linked
// dylib aborts the process at LAUNCH, before any Swift guard runs — and the CGS/SLS symbols
// live in SkyLight.framework, which is NOT auto-linked. So we resolve every private symbol at
// startup via dlsym into optional function pointers. If any is missing, `offSpaceSupported`
// is false and the app falls back to current-Space-only behavior (never crash, never regress).
//
// Signatures verified against AltTab's SkyLight.framework.swift (GPL-3).

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

private let RTLD_DEFAULT_HANDLE = UnsafeMutableRawPointer(bitPattern: -2)

private func loadSymbol<T>(_ name: String, _ type: T.Type) -> T? {
    guard let p = dlsym(RTLD_DEFAULT_HANDLE, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias FnMainConnectionID = @convention(c) () -> CGSConnectionID
typealias FnCopyManagedDisplaySpaces = @convention(c) (CGSConnectionID) -> CFArray?
typealias FnManagedDisplayGetCurrentSpace = @convention(c) (CGSConnectionID, CFString) -> CGSSpaceID
typealias FnCopyWindowsWithOptionsAndTags = @convention(c)
    (CGSConnectionID, Int, CFArray, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> CFArray?
typealias FnSetFrontProcessWithOptions = @convention(c)
    (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias FnPostEventRecordTo = @convention(c)
    (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
typealias FnCreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
typealias FnGetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
typealias FnGetActiveSpace = @convention(c) (CGSConnectionID) -> CGSSpaceID
typealias FnMoveWindowsToManagedSpace = @convention(c) (CGSConnectionID, CFArray, CGSSpaceID) -> Void

/// Resolved-once private API surface. Use `cgs` to access it.
struct CGSPrivate {
    let mainConnectionID: FnMainConnectionID?
    let copyManagedDisplaySpaces: FnCopyManagedDisplaySpaces?
    let managedDisplayGetCurrentSpace: FnManagedDisplayGetCurrentSpace?
    let copyWindowsWithOptionsAndTags: FnCopyWindowsWithOptionsAndTags?
    let setFrontProcessWithOptions: FnSetFrontProcessWithOptions?
    let postEventRecordTo: FnPostEventRecordTo?
    let createWithRemoteToken: FnCreateWithRemoteToken?
    let getProcessForPID: FnGetProcessForPID?
    /// Active Space + move-windows-to-Space, for the launcher's "bring an existing window to me"
    /// (no Space teleport). Resolved crash-safely; a missing symbol degrades to activate().
    let getActiveSpace: FnGetActiveSpace?
    let moveWindowsToManagedSpace: FnMoveWindowsToManagedSpace?

    /// Symbols required to ENUMERATE windows across all Spaces (and acquire off-Space AX
    /// elements). When false, snapshot() uses the legacy current-Space path.
    var offSpaceSupported: Bool {
        mainConnectionID != nil
            && copyManagedDisplaySpaces != nil
            && managedDisplayGetCurrentSpace != nil
            && copyWindowsWithOptionsAndTags != nil
            && createWithRemoteToken != nil
    }

    /// Symbols required to RAISE an off-Space window with a real Space switch. When false,
    /// raise() degrades to activate() + kAXRaiseAction.
    var offSpaceRaiseSupported: Bool {
        setFrontProcessWithOptions != nil && postEventRecordTo != nil && getProcessForPID != nil
    }

    init() {
        mainConnectionID = loadSymbol("CGSMainConnectionID", FnMainConnectionID.self)
        copyManagedDisplaySpaces = loadSymbol("CGSCopyManagedDisplaySpaces", FnCopyManagedDisplaySpaces.self)
        managedDisplayGetCurrentSpace = loadSymbol("CGSManagedDisplayGetCurrentSpace", FnManagedDisplayGetCurrentSpace.self)
        copyWindowsWithOptionsAndTags = loadSymbol("CGSCopyWindowsWithOptionsAndTags", FnCopyWindowsWithOptionsAndTags.self)
        setFrontProcessWithOptions = loadSymbol("_SLPSSetFrontProcessWithOptions", FnSetFrontProcessWithOptions.self)
        postEventRecordTo = loadSymbol("SLPSPostEventRecordTo", FnPostEventRecordTo.self)
        createWithRemoteToken = loadSymbol("_AXUIElementCreateWithRemoteToken", FnCreateWithRemoteToken.self)
        getProcessForPID = loadSymbol("GetProcessForPID", FnGetProcessForPID.self)
        getActiveSpace = loadSymbol("CGSGetActiveSpace", FnGetActiveSpace.self)
            ?? loadSymbol("SLSGetActiveSpace", FnGetActiveSpace.self)
        moveWindowsToManagedSpace = loadSymbol("SLSMoveWindowsToManagedSpace", FnMoveWindowsToManagedSpace.self)
            ?? loadSymbol("CGSMoveWindowsToManagedSpace", FnMoveWindowsToManagedSpace.self)
    }
}

let cgs = CGSPrivate()
