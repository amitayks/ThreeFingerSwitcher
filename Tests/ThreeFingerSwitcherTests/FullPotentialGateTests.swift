import XCTest
@testable import ThreeFingerSwitcherCore

/// Unit tests for the pure Full Potential gate (`AI/FullPotential/FullPotentialGate.swift`).
///
/// The gate is total and pure (no throw/async/IO), so the truth table is fully exhaustible here:
/// (a) AI-commands off ⇒ all locked; (b) master off ⇒ all locked; (c) with both masters on, one
/// sub-flag unlocks exactly one capability and no other; (d) `allCases` exhaustiveness.
final class FullPotentialGateTests: XCTestCase {

    // MARK: - Capability enum

    /// Exactly five capabilities, one per sub-flag (addendum §D1), with stable raw values.
    func testCapabilityHasFiveStableCases() {
        XCTAssertEqual(FullPotentialCapability.allCases.count, 5)
        XCTAssertEqual(FullPotentialCapability.cpuLane.rawValue, "cpuLane")
        XCTAssertEqual(FullPotentialCapability.batchedRuntime.rawValue, "batchedRuntime")
        XCTAssertEqual(FullPotentialCapability.mediaGen.rawValue, "mediaGen")
        XCTAssertEqual(FullPotentialCapability.backgroundAutonomy.rawValue, "backgroundAutonomy")
        XCTAssertEqual(FullPotentialCapability.fleetCloud.rawValue, "fleetCloud")
    }

    /// The raw values round-trip through `Codable` (so the enum can ride persistence/telemetry).
    func testCapabilityRawValueRoundTrips() {
        for cap in FullPotentialCapability.allCases {
            XCTAssertEqual(FullPotentialCapability(rawValue: cap.rawValue), cap)
        }
    }

    // MARK: - Flags value-type equality

    func testFlagsValueEquality() {
        let a = FullPotentialFlags(aiCommandsEnabled: true, fullPotentialEnabled: true,
                                   cpuLane: true, batchedRuntime: false, mediaGen: true,
                                   backgroundAutonomy: false, fleetCloud: true)
        var b = a
        XCTAssertEqual(a, b)
        b.mediaGen = false
        XCTAssertNotEqual(a, b, "flipping one field breaks equality")
    }

    // MARK: - Helpers

    /// All-on flags (AI-commands + master + every sub-flag) — the maximally-unlocked baseline.
    private func allOn() -> FullPotentialFlags {
        FullPotentialFlags(aiCommandsEnabled: true, fullPotentialEnabled: true,
                           cpuLane: true, batchedRuntime: true, mediaGen: true,
                           backgroundAutonomy: true, fleetCloud: true)
    }

    /// Flags with both masters on but every sub-flag OFF — the baseline for "one sub-flag unlocks one".
    private func mastersOnSubFlagsOff() -> FullPotentialFlags {
        FullPotentialFlags(aiCommandsEnabled: true, fullPotentialEnabled: true,
                           cpuLane: false, batchedRuntime: false, mediaGen: false,
                           backgroundAutonomy: false, fleetCloud: false)
    }

    /// Set exactly one capability's sub-flag to `value` on a copy of `base`.
    private func with(_ base: FullPotentialFlags, _ cap: FullPotentialCapability, _ value: Bool) -> FullPotentialFlags {
        var f = base
        switch cap {
        case .cpuLane:            f.cpuLane = value
        case .batchedRuntime:     f.batchedRuntime = value
        case .mediaGen:           f.mediaGen = value
        case .backgroundAutonomy: f.backgroundAutonomy = value
        case .fleetCloud:         f.fleetCloud = value
        }
        return f
    }

    // MARK: - (a) AI-commands off ⇒ all locked

    func testAICommandsOffLocksEverythingRegardless() {
        // Master + every sub-flag on, but AI-commands OFF: every capability is locked.
        var flags = allOn()
        flags.aiCommandsEnabled = false
        let gate = FullPotentialGate(flags: flags)
        for cap in FullPotentialCapability.allCases {
            XCTAssertFalse(gate.isUnlocked(cap), "\(cap) must be locked when AI-commands is off")
        }
    }

    // MARK: - (b) Master off ⇒ all locked

    func testMasterOffLocksEverything() {
        var flags = allOn()
        flags.fullPotentialEnabled = false
        let gate = FullPotentialGate(flags: flags)
        for cap in FullPotentialCapability.allCases {
            XCTAssertFalse(gate.isUnlocked(cap), "\(cap) must be locked when the master is off")
        }
    }

    // MARK: - All masters + sub-flags on ⇒ all unlocked

    func testAllOnUnlocksEverything() {
        let gate = FullPotentialGate(flags: allOn())
        for cap in FullPotentialCapability.allCases {
            XCTAssertTrue(gate.isUnlocked(cap), "\(cap) must be unlocked when all flags are on")
        }
    }

    // MARK: - (c) One sub-flag unlocks exactly its own capability

    func testEachSubFlagGatesExactlyItsOwnCapability() {
        for target in FullPotentialCapability.allCases {
            let flags = with(mastersOnSubFlagsOff(), target, true)
            let gate = FullPotentialGate(flags: flags)
            for cap in FullPotentialCapability.allCases {
                if cap == target {
                    XCTAssertTrue(gate.isUnlocked(cap), "\(target) on must unlock \(cap)")
                } else {
                    XCTAssertFalse(gate.isUnlocked(cap), "\(target) on must NOT unlock \(cap)")
                }
            }
        }
    }

    // MARK: - (d) Exhaustive gating across allCases

    /// With both masters on, the gate's answer for each capability equals exactly that capability's
    /// own stored sub-flag — proving no cross-talk and exhaustive coverage.
    func testGateMirrorsOwnSubFlagWhenMastersOn() {
        let flags = FullPotentialFlags(aiCommandsEnabled: true, fullPotentialEnabled: true,
                                       cpuLane: true, batchedRuntime: false, mediaGen: true,
                                       backgroundAutonomy: false, fleetCloud: true)
        let gate = FullPotentialGate(flags: flags)
        XCTAssertTrue(gate.isUnlocked(.cpuLane))
        XCTAssertFalse(gate.isUnlocked(.batchedRuntime))
        XCTAssertTrue(gate.isUnlocked(.mediaGen))
        XCTAssertFalse(gate.isUnlocked(.backgroundAutonomy))
        XCTAssertTrue(gate.isUnlocked(.fleetCloud))
    }

    // MARK: - Panic-off retains values (read-only gate)

    /// The gate never mutates its flags: flipping the master off and back on restores every capability
    /// (the stored sub-flags were retained — the gate relocks by computation, not by zeroing).
    func testPanicOffRetainsSubFlagsByComputation() {
        var flags = allOn()
        // Panic-off: master off ⇒ all locked, but the sub-flags are untouched.
        flags.fullPotentialEnabled = false
        let lockedGate = FullPotentialGate(flags: flags)
        for cap in FullPotentialCapability.allCases {
            XCTAssertFalse(lockedGate.isUnlocked(cap))
        }
        XCTAssertTrue(flags.cpuLane, "the gate did not zero the stored sub-flag")
        // Re-arm: master back on ⇒ the retained sub-flags unlock again.
        flags.fullPotentialEnabled = true
        let rearmedGate = FullPotentialGate(flags: flags)
        for cap in FullPotentialCapability.allCases {
            XCTAssertTrue(rearmedGate.isUnlocked(cap), "\(cap) restored on re-arm")
        }
    }
}
