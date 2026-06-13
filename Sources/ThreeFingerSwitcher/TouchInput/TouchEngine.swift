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

    /// Test-only convenience: build a frame from explicit normalized contact positions, so the
    /// positional model's footprint scaling can be exercised without fabricating `OMSTouchData`.
    /// The centroid is the mean of the points; `footprintSpread` is derived from them.
    init(testContactPoints points: [CGPoint], velocity: CGVector = .zero, time: CFTimeInterval = 0) {
        self.contacts = []
        self.testPoints = points
        self.fingerCount = points.count
        if points.isEmpty {
            self.centroid = .zero
        } else {
            let n = CGFloat(points.count)
            self.centroid = CGPoint(x: points.map(\.x).reduce(0, +) / n,
                                    y: points.map(\.y).reduce(0, +) / n)
        }
        self.centroidVelocity = velocity
        self.time = time
    }

    /// Test-only contact positions (set by `init(testContactPoints:)`); empty in real frames, which
    /// carry their per-contact positions in `contacts`. Lets `footprintSpread` work in both worlds.
    private var testPoints: [CGPoint] = []

    /// The per-contact normalized positions (0..1, OMS coords with y increasing upward), for drawing the
    /// fingertips in the Hub's live trackpad preview without importing the multitouch package. Empty for a
    /// count-only test frame; reads the injected points for an `init(testContactPoints:)` frame.
    var normalizedContactPoints: [CGPoint] {
        if !contacts.isEmpty {
            return contacts.map { CGPoint(x: CGFloat($0.position.x), y: CGFloat($0.position.y)) }
        }
        return testPoints
    }

    /// The fingers' landing **footprint** — the mean distance of the contacts from the centroid, in
    /// normalized trackpad units — or `nil` when no per-contact positions are available (e.g. a
    /// `TouchFrame(testFingerCount:)` frame, which carries only a count + centroid). The anchored
    /// positional model scales deflection by this so the same physical nudge means the same thing
    /// regardless of where (or how splayed) the hand landed; callers apply a fixed fallback when it is
    /// `nil` or near-zero (a single/degenerate contact). Real frames read `contacts[].position`;
    /// `init(testContactPoints:)` frames read the injected points.
    var footprintSpread: CGFloat? {
        let points: [CGPoint]
        if !contacts.isEmpty {
            points = contacts.map { CGPoint(x: CGFloat($0.position.x), y: CGFloat($0.position.y)) }
        } else if !testPoints.isEmpty {
            points = testPoints
        } else {
            return nil
        }
        guard points.count > 1 else { return 0 }   // a single contact has no spread → caller's fallback
        let c = centroid
        let total = points.reduce(CGFloat(0)) { acc, p in
            acc + hypot(p.x - c.x, p.y - c.y)
        }
        return total / CGFloat(points.count)
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
