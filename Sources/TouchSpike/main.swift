// TouchSpike — throwaway verification harness for Section 1 spikes.
//
// Purpose (run on the dev machine with a trackpad):
//   1.1 Confirm a live touch stream prints frames (symbols load on macOS 26 Tahoe).
//   1.2 Stream emission shape — RESOLVED from source: each emission is a FRAME SNAPSHOT
//       ([OMSTouchData]); finger count = touches in contact states in that frame.
//       This harness prints frame size + states so the shape is also observable live.
//   1.3 Observe whether starting the read triggers an Input Monitoring TCC prompt.
//
// Usage:
//   swift run TouchSpike
//   Then place 1, then 2, then 3 fingers on the trackpad. Ctrl-C to stop.

import Foundation
import OpenMultitouchSupport

setbuf(stdout, nil) // unbuffer so frames appear live even when piped to a file

// Contact states = finger physically on the surface (excludes hovering/leaving/breaking).
func isContact(_ s: OMSState) -> Bool {
    switch s {
    case .starting, .making, .touching, .lingering: return true
    case .notTouching, .hovering, .breaking, .leaving: return false
    }
}

print("== TouchSpike ==")
print("If a system 'Input Monitoring' prompt appears now, note it (spike 1.3).")
print("Place 1, then 2, then 3 fingers on the trackpad. Ctrl-C to stop.\n")

let manager = OMSManager.shared
let started = manager.startListening()
print("startListening() returned: \(started)")
if !started {
    print("ERROR: could not start listening — symbols missing or device unavailable (spike 1.1 FAIL).")
    exit(1)
}

let consumer = Task {
    var frameCount = 0
    var maxContacts = 0
    for await frame in manager.touchDataStream {
        frameCount += 1
        let contacts = frame.filter { isContact($0.state) }
        maxContacts = max(maxContacts, contacts.count)
        // Only log frames with at least one contact, to reduce noise.
        if !contacts.isEmpty {
            let ids = contacts.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",")
            let cx = contacts.map(\.position.x).reduce(0, +) / Float(contacts.count)
            let cy = contacts.map(\.position.y).reduce(0, +) / Float(contacts.count)
            print(String(format: "frame#%d  contacts=%d  centroid=(%.3f,%.3f)  [%@]",
                         frameCount, contacts.count, cx, cy, ids))
            if contacts.count == 3 {
                print("  >> THREE FINGERS DETECTED (finger-count derivation works)")
            }
        }
    }
    print("\nstream ended. frames=\(frameCount) maxContacts=\(maxContacts)")
}

signal(SIGINT) { _ in
    print("\nSIGINT — stopping.")
    _ = OMSManager.shared.stopListening()
    exit(0)
}

// Keep the process alive for async stream delivery.
RunLoop.main.run()
_ = consumer
