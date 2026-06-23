import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the `ai-background-autonomy` slice (tasks §1–§5): blast-radius classification (§1), the
/// whitelist matching rules (§2), effective-tier resolution (§3), the auto-vs-escalate gate (§4), and the
/// append-only redacted audit log (§5). Everything is MLX-free Core, driven with fabricated
/// `ToolDescriptor`s — no model. `@MainActor` because `AppSettings` keys exercised here are main-actor.
@MainActor
final class BackgroundAutonomyTests: XCTestCase {

    // MARK: - Helpers

    private func descriptor(_ name: String, tier: WritePolicyTier) -> ToolDescriptor {
        ToolDescriptor(name: name, summary: "tool \(name)",
                       argsSchema: StructuredSchema(name: name, json: "{\"type\":\"object\"}"),
                       writePolicy: tier)
    }

    private func sid() -> AgentSessionID { AgentSessionID() }

    // MARK: - 1. Blast-radius classification

    func testContainedToolsClassifyContained() {
        for name in ["memory.read", "memory.write", "save_to_project:Inbox", "retrieve", "widen_candidates"] {
            XCTAssertEqual(BlastRadius.of(descriptor(name, tier: .auto)), .contained, "\(name)")
        }
    }

    func testExternalConfirmToolsClassifyExternal() {
        for name in ["add_to_calendar", "add_to_reminders", "new_contact", "open_tool_with_payload:notes", "send_to:slack"] {
            XCTAssertEqual(BlastRadius.of(descriptor(name, tier: .confirm)), .external, "\(name)")
        }
    }

    func testDangerousIsUnconditionalAndIgnoresName() {
        // A .dangerous descriptor classifies dangerous even with a CONTAINED-looking name.
        XCTAssertEqual(BlastRadius.of(descriptor("memory.write", tier: .dangerous)), .dangerous)
        XCTAssertEqual(BlastRadius.of(descriptor("delete_file", tier: .dangerous)), .dangerous)
        XCTAssertEqual(BlastRadius.of(descriptor("send_to:shell", tier: .dangerous)), .dangerous)
    }

    func testContainedPrefixSetMatchesByPrefix() {
        XCTAssertTrue(BlastRadius.isContainedName("memory.write.core"))
        XCTAssertTrue(BlastRadius.isContainedName("save_to_project:Big Project"))
        XCTAssertFalse(BlastRadius.isContainedName("write_memory"))   // not a prefix
        XCTAssertFalse(BlastRadius.isContainedName("open_tool"))
    }

    // MARK: - 2. Whitelist — path matching

    func testPathMatchRespectsComponentBoundary() {
        let wl = Whitelist(trustedPathPrefixes: ["/Users/me/Notes"])
        XCTAssertTrue(wl.matchesPath("/Users/me/Notes/x.md"))
        XCTAssertTrue(wl.matchesPath("/Users/me/Notes"))            // the prefix itself
        XCTAssertFalse(wl.matchesPath("/Users/me/Notes2/x.md"))     // string-prefix-only, NOT a boundary
        XCTAssertFalse(wl.matchesPath("/Users/me/Other/x.md"))
    }

    func testPathMatchResolvesDotDotEscape() {
        let wl = Whitelist(trustedPathPrefixes: ["/Users/me/Notes"])
        // `/Users/me/Notes/../etc/passwd` standardizes to `/Users/me/etc/passwd` → does NOT match.
        XCTAssertFalse(wl.matchesPath("/Users/me/Notes/../etc/passwd"))
    }

    func testEmptyWhitelistMatchesNothing() {
        XCTAssertFalse(Whitelist.empty.matchesPath("/Users/me/Notes/x.md"))
        XCTAssertFalse(Whitelist.empty.matchesCommand("git"))
        XCTAssertEqual(Whitelist.empty.trustedPathPrefixes, [])
        XCTAssertEqual(Whitelist.empty.trustedCommandPatterns, [])
    }

    // MARK: - 2. Whitelist — command glob

    func testCommandGlobIsAnchoredFullString() {
        let wl = Whitelist(trustedCommandPatterns: ["git*"])
        XCTAssertTrue(wl.matchesCommand("git"))
        XCTAssertTrue(wl.matchesCommand("git-lfs"))
        XCTAssertFalse(wl.matchesCommand("forgit"))     // anchored: pattern must match from the start
    }

    func testCommandGlobQuestionMark() {
        let wl = Whitelist(trustedCommandPatterns: ["ls?"])
        XCTAssertTrue(wl.matchesCommand("lsx"))
        XCTAssertFalse(wl.matchesCommand("ls"))         // `?` requires exactly one char
        XCTAssertFalse(wl.matchesCommand("lsxx"))
    }

    func testGlobMatchPureHelper() {
        XCTAssertTrue(Whitelist.globMatch(pattern: "*", name: "anything"))
        XCTAssertTrue(Whitelist.globMatch(pattern: "a*b*c", name: "axxbyyc"))
        XCTAssertFalse(Whitelist.globMatch(pattern: "a*b*c", name: "axxbyy"))
        XCTAssertTrue(Whitelist.globMatch(pattern: "exact", name: "exact"))
    }

    // MARK: - 2. Whitelist — both-rule

    func testBothRuleRequiresCommandAndPath() {
        let wl = Whitelist(trustedPathPrefixes: ["/Users/me/Repo"], trustedCommandPatterns: ["git*"])
        // Whitelisted command at a trusted path → matches.
        XCTAssertTrue(wl.matchesBoth(command: "git", path: "/Users/me/Repo/file.txt"))
        // Whitelisted command at an OFF-list path → does NOT match (stricter wins).
        XCTAssertFalse(wl.matchesBoth(command: "git", path: "/tmp/file.txt"))
        // Off-list command at a trusted path → does NOT match.
        XCTAssertFalse(wl.matchesBoth(command: "rm", path: "/Users/me/Repo/file.txt"))
    }

    func testWhitelistCodableRoundTrip() throws {
        let wl = Whitelist(trustedPathPrefixes: ["/a/b"], trustedCommandPatterns: ["git*", "node"])
        let data = try JSONEncoder().encode(wl)
        let back = try JSONDecoder().decode(Whitelist.self, from: data)
        XCTAssertEqual(wl, back)
    }

    // MARK: - 3. Effective-tier resolution (the full table)

    func testResolutionContainedIsAuto() {
        let r = BackgroundPolicyResolver(whitelist: .empty)
        XCTAssertEqual(r.effectiveTier(for: descriptor("memory.write", tier: .auto)), .auto)
        XCTAssertEqual(r.effectiveTier(for: descriptor("memory.write", tier: .auto), target: PolicyTarget.none), .auto)
    }

    func testResolutionDangerousNeverLowered() {
        // Even a whitelisted path cannot lower a .dangerous descriptor.
        let wl = Whitelist(trustedPathPrefixes: ["/Users/me/Notes"])
        let r = BackgroundPolicyResolver(whitelist: wl)
        let d = descriptor("delete_file", tier: .dangerous)
        XCTAssertEqual(r.effectiveTier(for: d), .dangerous)
        XCTAssertEqual(r.effectiveTier(for: d, target: .path("/Users/me/Notes/x.md")), .dangerous)
    }

    func testResolutionConfirmLowersOnMatch() {
        let wl = Whitelist(trustedPathPrefixes: ["/Users/me/Notes"], trustedCommandPatterns: ["git*"])
        let r = BackgroundPolicyResolver(whitelist: wl)
        let d = descriptor("send_to:script", tier: .confirm)
        // path match → auto
        XCTAssertEqual(r.effectiveTier(for: d, target: .path("/Users/me/Notes/out.md")), .auto)
        // command match → auto
        XCTAssertEqual(r.effectiveTier(for: d, target: .command("git")), .auto)
        // both match → auto
        XCTAssertEqual(r.effectiveTier(for: d, target: .both(command: "git", path: "/Users/me/Notes/out.md")), .auto)
    }

    func testResolutionConfirmStaysOnNoMatch() {
        let r = BackgroundPolicyResolver(whitelist: .empty)
        let d = descriptor("send_to:script", tier: .confirm)
        XCTAssertEqual(r.effectiveTier(for: d, target: .path("/tmp/out.md")), .confirm)
        XCTAssertEqual(r.effectiveTier(for: d, target: .command("rm")), .confirm)
        XCTAssertEqual(r.effectiveTier(for: d, target: PolicyTarget.none), .confirm)  // .none never lowerable
        XCTAssertEqual(r.effectiveTier(for: d, target: nil), .confirm)
        XCTAssertEqual(r.effectiveTier(for: d), .confirm)                              // descriptor-only fast path
    }

    func testResolverSatisfiesProtocol() {
        // The descriptor-only protocol method (the routing seam) is satisfied.
        let r: WritePolicyResolving = BackgroundPolicyResolver(whitelist: .empty)
        XCTAssertEqual(r.effectiveTier(for: descriptor("add_to_calendar", tier: .confirm)), .confirm)
    }

    // MARK: - 4. Background gate (the full decision table)

    func testGateAutoRunsWhileParkedAndActive() {
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .auto, parkState: .parked), .auto)
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .auto, parkState: .idle), .auto)
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .auto, parkState: .active), .auto)
    }

    func testGateConfirmWaitsParkedDefersForeground() {
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .confirm, parkState: .parked), .waitParked)
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .confirm, parkState: .idle), .waitParked)
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .confirm, parkState: .active), .foreground)
    }

    func testGateDangerousEscalatesWhileParked() {
        let decision = BackgroundGate.decide(effectiveTier: .dangerous, parkState: .parked, tool: "delete_file")
        if case let .escalate(reason) = decision {
            XCTAssertTrue(reason.contains("delete_file"))
            XCTAssertTrue(reason.contains("approval"))
        } else {
            XCTFail("expected .escalate, got \(decision)")
        }
        // Active → the canvas approval gate owns it (no glow).
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .dangerous, parkState: .active), .foreground)
    }

    func testGateNeverDoubleEscalates() {
        // Already in needs-you → any tier waits (do not double-escalate / re-glow).
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .dangerous, parkState: .needsYou), .waitParked)
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .confirm, parkState: .needsYou), .waitParked)
        XCTAssertEqual(BackgroundGate.decide(effectiveTier: .auto, parkState: .needsYou), .waitParked)
    }

    // MARK: - 5. Audit record + redaction

    func testRedactionTruncatesLongArguments() {
        let long = String(repeating: "x", count: 300)
        let summary = AuditRedaction.summary(forRawArguments: long)
        XCTAssertLessThanOrEqual(summary.count, AuditRedaction.maxSummaryLength)
        XCTAssertTrue(summary.contains("\u{2026}"))   // middle-truncation ellipsis
    }

    func testRedactionStripsEmbeddedSecret() {
        let line = "deploy --token abcdef0123456789 --target prod"
        let summary = AuditRedaction.summary(forRawArguments: line)
        XCTAssertFalse(summary.contains("abcdef0123456789"), "raw token leaked: \(summary)")
    }

    func testRedactionPathShowsLastComponentsOnly() {
        let summary = AuditRedaction.summary(for: .path("/Users/me/Secret/Tree/note.md"))
        XCTAssertTrue(summary.contains("note.md"))
        XCTAssertFalse(summary.contains("/Users/me/Secret"))   // full tree not leaked
    }

    func testRedactionCommandShowsNameNotFullLine() {
        let summary = AuditRedaction.summary(for: .command("/usr/bin/git push --token SECRETTOKEN1234"))
        XCTAssertTrue(summary.contains("git"))
        XCTAssertFalse(summary.contains("SECRETTOKEN1234"))
    }

    func testAuditRecordCodableRoundTripFailedHeadlineOnly() throws {
        let rec = AuditRecord(sessionID: sid(), tool: "send_to:slack", policy: .confirm,
                              argumentsSummary: "$ slack → #general",
                              outcome: .failed(headline: "Couldn't reach Slack."),
                              wasBackground: true,
                              timestamp: Date(timeIntervalSince1970: 1000))
        let data = try JSONEncoder().encode(rec)
        let back = try JSONDecoder().decode(AuditRecord.self, from: data)
        XCTAssertEqual(rec, back)
        if case let .failed(headline) = back.outcome {
            XCTAssertEqual(headline, "Couldn't reach Slack.")
        } else {
            XCTFail("expected .failed outcome")
        }
    }

    // MARK: - 5. In-memory audit ring

    func testInMemoryRingAppendsAndReadsReverseChronological() {
        let log = InMemoryAuditLog(cap: 100)
        let s = sid()
        for i in 0..<3 {
            log.record(AuditRecord(sessionID: s, tool: "t\(i)", policy: .auto,
                                   argumentsSummary: "a\(i)", outcome: .done, wasBackground: true,
                                   timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        let recent = log.recent(limit: 10)
        XCTAssertEqual(recent.map(\.tool), ["t2", "t1", "t0"])   // reverse-chronological
    }

    func testInMemoryRingCapTrimsOldest() {
        let log = InMemoryAuditLog(cap: 2)
        let s = sid()
        for i in 0..<5 {
            log.record(AuditRecord(sessionID: s, tool: "t\(i)", policy: .auto,
                                   argumentsSummary: "a", outcome: .done, wasBackground: false))
        }
        let recent = log.recent(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.map(\.tool), ["t4", "t3"])         // oldest trimmed
    }

    func testRecordIsAppendOnlyAcrossOutcomes() {
        // Every outcome variety writes one record (the "what did my agents do" ledger).
        let log = InMemoryAuditLog(cap: 100)
        let s = sid()
        let outcomes: [ToolStepStatus] = [.done, .declined(reason: "skip"), .awaitingApproval,
                                          .failed(headline: "nope")]
        for (i, o) in outcomes.enumerated() {
            log.record(AuditRecord(sessionID: s, tool: "t\(i)", policy: .auto,
                                   argumentsSummary: "a", outcome: o, wasBackground: true))
        }
        XCTAssertEqual(log.recent(limit: 10).count, outcomes.count)
    }

    // MARK: - 5. Disk audit log (temp dir)

    func testDiskAuditLogRoundTripAndReload() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-audit-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("audit.jsonl")
        let s = sid()

        let log = DiskAuditLog(fileURL: file, cap: 100)
        for i in 0..<3 {
            log.record(AuditRecord(sessionID: s, tool: "t\(i)", policy: .auto,
                                   argumentsSummary: "a\(i)", outcome: .done, wasBackground: true,
                                   timestamp: Date(timeIntervalSince1970: Double(i))))
        }
        // The off-main writer is async — drain it before reloading.
        let exp = expectation(description: "persisted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertNil(log.lastPersistError)

        // A fresh store over the same file rebuilds the ring from disk.
        let reloaded = DiskAuditLog(fileURL: file, cap: 100)
        XCTAssertEqual(reloaded.recent(limit: 10).map(\.tool), ["t2", "t1", "t0"])

        try? FileManager.default.removeItem(at: dir)
    }

    func testDiskAuditLogTrimsToCapOnWrite() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tfs-audit-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("audit.jsonl")
        let s = sid()

        let log = DiskAuditLog(fileURL: file, cap: 2)
        for i in 0..<5 {
            log.record(AuditRecord(sessionID: s, tool: "t\(i)", policy: .auto,
                                   argumentsSummary: "a", outcome: .done, wasBackground: false))
        }
        let exp = expectation(description: "persisted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let reloaded = DiskAuditLog(fileURL: file, cap: 2)
        XCTAssertEqual(reloaded.recent(limit: 10).count, 2)
        XCTAssertEqual(reloaded.recent(limit: 10).map(\.tool), ["t4", "t3"])

        try? FileManager.default.removeItem(at: dir)
    }

    func testFailablePersistIsObservableNotThrown() {
        // A persistence failure surfaces on `lastPersistError` but never throws into the caller and never
        // loses the in-memory record (auditing must not break the agent).
        let log = FailableInMemoryAuditLog(cap: 100)
        log.failPersist = true
        let s = sid()
        log.record(AuditRecord(sessionID: s, tool: "t", policy: .auto, argumentsSummary: "a",
                               outcome: .done, wasBackground: true))   // does not throw
        XCTAssertEqual(log.recent(limit: 10).count, 1)                 // record still present
        XCTAssertNotNil(log.lastPersistError)
    }

    // MARK: - 5/7. AuditError routes through the single translator

    func testAuditErrorRoutesThroughAIError() {
        for err: AuditError in [.persistFailed(detail: "disk full at /x/y raw OS text"),
                                .storeUnavailable(detail: "EACCES raw")] {
            let presented = AIError.message(for: err)
            XCTAssertFalse(presented.headline.isEmpty)
            XCTAssertNotEqual(presented.headline, AIError.unknownHeadline)
            XCTAssertFalse(presented.headline.contains("raw"), "raw OS text leaked into headline")
            XCTAssertFalse(presented.headline.contains("EACCES"))
        }
    }

    // MARK: - AppSettings whitelist persistence + reset

    func testWhitelistDefaultsEmptyPersistAndResetPreserves() {
        let suite = "tfs-bgauto-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.agentWhitelistPaths, [])
        XCTAssertEqual(settings.agentWhitelistCommands, [])
        XCTAssertEqual(settings.agentWhitelist, .empty)

        settings.agentWhitelistPaths = ["/Users/me/Notes"]
        settings.agentWhitelistCommands = ["git*"]

        // Persists across a fresh instance over the same defaults.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.agentWhitelistPaths, ["/Users/me/Notes"])
        XCTAssertEqual(reloaded.agentWhitelistCommands, ["git*"])
        XCTAssertEqual(reloaded.agentWhitelist,
                       Whitelist(trustedPathPrefixes: ["/Users/me/Notes"], trustedCommandPatterns: ["git*"]))

        // A reset-to-defaults preserves the trust choice (like the other AI opt-ins).
        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.agentWhitelistPaths, ["/Users/me/Notes"])
        XCTAssertEqual(reloaded.agentWhitelistCommands, ["git*"])
    }
}
