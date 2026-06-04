import Foundation
import QuartzCore
import OpenMultitouchSupport

/// One processed frame of trackpad state derived from a raw OpenMultitouchSupport snapshot.
struct TouchFrame {
    /// Touches currently in contact with the surface.
    let contacts: [OMSTouchData]
    /// Finger count for this frame. Equals `contacts.count` in real construction; tests can
    /// inject a count directly (without fabricating `OMSTouchData` contacts).
    let fingerCount: Int
    /// Mean position of contacts, normalized 0..1. Zero vector when no contacts.
    let centroid: CGPoint
    /// EMA-smoothed centroid velocity in normalized units per second.
    let centroidVelocity: CGVector
    /// Monotonic timestamp (seconds).
    let time: CFTimeInterval

    /// Real construction from a processed snapshot. `fingerCount` is derived from `contacts`
    /// (see TouchEngine.isContact). Keeps the original call sites unchanged.
    init(contacts: [OMSTouchData], centroid: CGPoint, centroidVelocity: CGVector, time: CFTimeInterval) {
        self.contacts = contacts
        self.fingerCount = contacts.count
        self.centroid = centroid
        self.centroidVelocity = centroidVelocity
        self.time = time
    }

    /// Test-only convenience: build a frame from a finger count + centroid without fabricating
    /// `OMSTouchData` contacts. The recognizer only reads `fingerCount` and `centroid`.
    init(testFingerCount: Int, centroid: CGPoint, velocity: CGVector = .zero, time: CFTimeInterval = 0) {
        self.contacts = []
        self.fingerCount = testFingerCount
        self.centroid = centroid
        self.centroidVelocity = velocity
        self.time = time
    }
}

/// Wraps OpenMultitouchSupport: starts/stops the passive read and forwards processed
/// `TouchFrame`s on the main actor. Derives finger count (frame snapshot) and velocity
/// (Δposition/Δt), neither of which the package provides.
@MainActor
final class TouchEngine {
    /// Called for every processed frame while listening (including empty frames on lift).
    var onFrame: ((TouchFrame) -> Void)?

    private(set) var isListening = false
    /// Best-effort: false when the multitouch manager could not start (e.g. no trackpad).
    private(set) var isAvailable = true

    private let manager = OMSManager.shared
    private var consumer: Task<Void, Never>?

    private var lastCentroid: CGPoint?
    private var lastTime: CFTimeInterval?
    private var smoothedVelocity = CGVector.zero

    /// Contact = finger physically on the surface. Excludes hovering/leaving/breaking.
    static func isContact(_ s: OMSState) -> Bool {
        switch s {
        case .starting, .making, .touching, .lingering: return true
        case .notTouching, .hovering, .breaking, .leaving: return false
        }
    }

    func start() {
        guard !isListening else { return }
        let started = manager.startListening()
        isAvailable = started
        guard started else { return }
        isListening = true
        resetMotion()

        consumer = Task { @MainActor [weak self] in
            guard let self else { return }
            for await frame in manager.touchDataStream {
                if Task.isCancelled { break }
                self.process(frame)
            }
        }
    }

    func stop() {
        guard isListening else { return }
        consumer?.cancel()
        consumer = nil
        _ = manager.stopListening()
        isListening = false
        resetMotion()
    }

    private func resetMotion() {
        lastCentroid = nil
        lastTime = nil
        smoothedVelocity = .zero
    }

    private func process(_ raw: [OMSTouchData]) {
        let contacts = raw.filter { Self.isContact($0.state) }
        let now = CACurrentMediaTime()

        guard !contacts.isEmpty else {
            // All fingers lifted: emit an empty frame so the recognizer can end a gesture.
            resetMotion()
            onFrame?(TouchFrame(contacts: [], centroid: .zero, centroidVelocity: .zero, time: now))
            return
        }

        let cx = contacts.map { CGFloat($0.position.x) }.reduce(0, +) / CGFloat(contacts.count)
        let cy = contacts.map { CGFloat($0.position.y) }.reduce(0, +) / CGFloat(contacts.count)
        let centroid = CGPoint(x: cx, y: cy)

        let alpha = CGFloat(AppSettings.shared.velocitySmoothing)
        if let prev = lastCentroid, let prevT = lastTime, now > prevT {
            let dt = CGFloat(now - prevT)
            let instantaneous = CGVector(dx: (centroid.x - prev.x) / dt, dy: (centroid.y - prev.y) / dt)
            smoothedVelocity = CGVector(
                dx: alpha * instantaneous.dx + (1 - alpha) * smoothedVelocity.dx,
                dy: alpha * instantaneous.dy + (1 - alpha) * smoothedVelocity.dy
            )
        }
        lastCentroid = centroid
        lastTime = now

        onFrame?(TouchFrame(contacts: contacts, centroid: centroid, centroidVelocity: smoothedVelocity, time: now))
    }
}
