import Foundation

/// The injected memory-pressure seam (`model-idle-ttl-and-memory-pressure` D3): `ModelManager`
/// consumes this protocol; the app composition root installs the real `DispatchSource` wrapper and
/// Core tests install the settable fake. Keeping the seam in Core (Dispatch is MLX-free) lets the
/// whole eviction path verify under `swift build` / `swift test`.
@MainActor
public protocol MemoryPressureObserving: AnyObject {
    /// The most recent level. `.nominal` until the OS reports otherwise.
    var level: MemoryPressureLevel { get }
    /// Set by `ModelManager` — called on the main actor whenever the level changes, so the policy is
    /// evaluated immediately on a pressure event (pressure can persist; the coarse tick re-checks).
    var onChange: (@MainActor (MemoryPressureLevel) -> Void)? { get set }
}

/// The settable fake for tests and the MLX-free dev build.
@MainActor
public final class FakeMemoryPressureSource: MemoryPressureObserving {
    public private(set) var level: MemoryPressureLevel
    public var onChange: (@MainActor (MemoryPressureLevel) -> Void)?

    public init(level: MemoryPressureLevel = .nominal) {
        self.level = level
    }

    public func report(_ new: MemoryPressureLevel) {
        level = new
        onChange?(new)
    }
}

/// The real observer: a thin wrapper over `DispatchSource.makeMemoryPressureSource`. This is the
/// piece the old code comments claimed existed ("evict on memory pressure") but never wired. Events
/// are delivered onto the main actor to match `ModelManager`'s isolation. `.normal` transitions are
/// also observed so a relieved system returns the level to `.nominal` (otherwise one warning would
/// pin the policy at `.warning` forever).
@MainActor
public final class SystemMemoryPressureSource: MemoryPressureObserving {
    public private(set) var level: MemoryPressureLevel = .nominal
    public var onChange: (@MainActor (MemoryPressureLevel) -> Void)?

    private let source: DispatchSourceMemoryPressure

    public init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                                                         queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            let new: MemoryPressureLevel
            if event.contains(.critical) {
                new = .critical
            } else if event.contains(.warning) {
                new = .warning
            } else {
                new = .nominal
            }
            MainActor.assumeIsolated {
                self.level = new
                self.onChange?(new)
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
