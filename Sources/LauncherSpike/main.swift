// LauncherSpike — throwaway verification harness for the four-finger-launcher Section-1 spikes.
//
//   S-OQ3  Resolve the private window-move symbol used to bring a window to the current Space
//          WITHOUT switching Spaces. Symbol resolution is TCC-independent, so this is definitive
//          even from an ad-hoc build.   →  `swift run LauncherSpike` (default: symbols)
//   S-OQ1  Haptic actuation. Fires NSHapticFeedbackManager ticks after a delay (no click in flight)
//          so you can feel whether the Taptic Engine actuates.   →  `swift run LauncherSpike haptic`
//
// Usage:
//   swift run LauncherSpike            # probe window-move + space symbols, print what resolves
//   swift run LauncherSpike haptic     # fire 3 haptic ticks over ~3s; report if you feel them

import AppKit

private func resolves(_ name: String) -> Bool {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
}

func probeSymbols() {
    print("== LauncherSpike: symbol resolution (RTLD_DEFAULT) ==\n")

    // Candidate names for "move windows to a managed Space" (no Space switch). yabai/AltTab lineage.
    let moveCandidates = [
        "SLSMoveWindowsToManagedSpace",
        "CGSMoveWindowsToManagedSpace",
        "SLSMoveWindowToManagedSpace",
        "CGSManagedDisplaySetCurrentSpace",
        "CGSAddWindowsToSpaces",
        "CGSRemoveWindowsFromSpaces",
        "CGSSetWindowListWorkspace",
    ]
    // Supporting symbols for resolving the current Space / connection (some already used in-app).
    let supportCandidates = [
        "CGSMainConnectionID",
        "SLSMainConnectionID",
        "CGSManagedDisplayGetCurrentSpace",
        "SLSManagedDisplayGetCurrentSpace",
        "CGSCopyManagedDisplaySpaces",
        "CGSGetActiveSpace",
        "SLSGetActiveSpace",
    ]

    print("-- window-move candidates --")
    for name in moveCandidates { print(String(format: "  [%@] %@", resolves(name) ? "✓" : " ", name)) }
    print("\n-- supporting candidates --")
    for name in supportCandidates { print(String(format: "  [%@] %@", resolves(name) ? "✓" : " ", name)) }

    let firstMove = moveCandidates.first(where: resolves)
    print("\nRESULT: window-move symbol = \(firstMove.map { "\"\($0)\"" } ?? "NONE RESOLVED")")
    if firstMove == nil {
        print("  ⚠️ No move symbol resolved here — SkyLight may not be loaded in this CLI context.")
        print("     (CoreGraphics IS linked via AppKit, so SLS/CGS should be present; if not, the")
        print("      in-app context resolves them because the app links the same frameworks.)")
    }
}

func fireHaptics() {
    print("== LauncherSpike: haptic actuation (S-OQ1) ==")
    print("Take your hand OFF the trackpad. 3 ticks will fire over ~3 seconds.")
    print("Report whether you FEEL each tick.\n")
    let performer = NSHapticFeedbackManager.defaultPerformer
    for i in 1...3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) {
            performer.perform(.alignment, performanceTime: .now)
            print("  tick #\(i) fired (.alignment)")
            if i == 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            }
        }
    }
    RunLoop.main.run()
}

let mode = CommandLine.arguments.dropFirst().first ?? "symbols"
switch mode {
case "haptic", "haptics": fireHaptics()
default: probeSymbols()
}
