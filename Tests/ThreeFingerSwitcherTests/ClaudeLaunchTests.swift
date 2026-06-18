import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the Open-Claude-Here pieces: the `.claudeProject` kind's Codable forward-compat and default
/// appearance, the pure `.command` script builder, and the `ClaudeLaunchError` taxonomy. The shell
/// resolver (`resolveClaudePath`) is intentionally not unit-tested — it spawns a login shell and depends
/// on whether `claude` is installed on the host, which a CI box can't guarantee.
final class ClaudeLaunchTests: XCTestCase {

    // MARK: - 4.1 Codable round-trip + legacy decode

    func testCodableRoundTripWithPath() throws {
        let item = ClaudeLauncher.makeItem(folder: URL(fileURLWithPath: "/tmp/Repo"),
                                           claudePath: "/usr/local/bin/claude")
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
    }

    func testCodableRoundTripWithoutPath() throws {
        let item = ClaudeLauncher.makeItem(folder: URL(fileURLWithPath: "/tmp/Repo"), claudePath: nil)
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case let .claudeProject(_, command, path) = decoded.kind else { return XCTFail("wrong kind") }
        XCTAssertNil(command)
        XCTAssertNil(path)
    }

    func testCodableRoundTripWithCommand() throws {
        let folder = URL(fileURLWithPath: "/tmp/Repo")
        var item = ClaudeLauncher.makeItem(folder: folder, claudePath: "/bin/claude")
        item.kind = .claudeProject(folder: folder, command: "claude --resume", claudePath: "/bin/claude")
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case let .claudeProject(_, command, _) = decoded.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(command, "claude --resume")
    }

    /// A record written before `claudePath` existed (the key absent) still decodes — claudePath → nil.
    func testLegacyDecodeWithoutClaudePathKey() throws {
        let folder = URL(fileURLWithPath: "/tmp/MyRepo")
        let item = ClaudeLauncher.makeItem(folder: folder, claudePath: "/usr/local/bin/claude")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
        let stripped = Self.removingKey("claudePath", from: object)
        let data = try JSONSerialization.data(withJSONObject: stripped)
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: data)
        guard case let .claudeProject(decodedFolder, _, path) = decoded.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(decodedFolder, folder)
        XCTAssertNil(path)
    }

    /// Recursively drop every occurrence of `name` from a decoded JSON object (robust to nesting / URL
    /// representation), to simulate a record written before the field existed.
    private static func removingKey(_ name: String, from object: Any) -> Any {
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, value) in dict where key != name { out[key] = removingKey(name, from: value) }
            return out
        }
        if let array = object as? [Any] { return array.map { removingKey(name, from: $0) } }
        return object
    }

    // MARK: - 4.2 Default appearance

    func testMakeItemDefaultAppearance() {
        let folder = URL(fileURLWithPath: "/Users/me/Projects/cool-thing")
        let item = ClaudeLauncher.makeItem(folder: folder, claudePath: "/usr/local/bin/claude")
        XCTAssertEqual(item.title, "cool-thing")          // title = folder's last path component
        XCTAssertEqual(item.icon, .sfSymbol("sparkles"))
        XCTAssertTrue(item.isConsequential)               // a launch worth a failure notification
        guard case let .claudeProject(f, _, p) = item.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(f, folder)
        XCTAssertEqual(p, "/usr/local/bin/claude")
    }

    // MARK: - 4.3 Command script

    func testCommandScriptWithResolvedPath() {
        let script = ClaudeLauncher.commandScript(folder: URL(fileURLWithPath: "/Users/me/My Repo"),
                                                  command: nil, claudePath: "/usr/local/bin/claude")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh"))
        XCTAssertTrue(script.contains("rm -f \"$0\""))                 // self-delete
        XCTAssertTrue(script.contains("cd '/Users/me/My Repo'"))      // cd into the folder (quoted)
        XCTAssertTrue(script.contains("exec /bin/zsh -lic"))          // via a login+interactive shell
        XCTAssertTrue(script.contains("/usr/local/bin/claude"))       // runs the resolved binary
    }

    func testCommandScriptFallbackWhenNoPath() {
        let script = ClaudeLauncher.commandScript(folder: URL(fileURLWithPath: "/tmp/x"), command: nil, claudePath: nil)
        XCTAssertTrue(script.contains("cd '/tmp/x'"))
        XCTAssertTrue(script.contains("rm -f \"$0\""))
        XCTAssertTrue(script.contains("exec /bin/zsh -lic 'claude'")) // claude from PATH fallback
    }

    func testCommandScriptTreatsBlankPathAsNoPath() {
        let script = ClaudeLauncher.commandScript(folder: URL(fileURLWithPath: "/tmp/x"), command: nil, claudePath: "   ")
        XCTAssertTrue(script.contains("exec /bin/zsh -lic 'claude'"))
    }

    func testCommandScriptWithCustomCommand() {
        let script = ClaudeLauncher.commandScript(folder: URL(fileURLWithPath: "/tmp/x"),
                                                  command: "claude --resume", claudePath: "/usr/local/bin/claude")
        XCTAssertTrue(script.contains("exec /bin/zsh -lic 'claude --resume'"))  // run as written
        XCTAssertFalse(script.contains("/usr/local/bin/claude"))               // resolved path ignored for a custom command
    }

    func testCommandScriptEscapesQuotesInCustomCommand() {
        let command = "claude -p 'hello world'"
        let script = ClaudeLauncher.commandScript(folder: URL(fileURLWithPath: "/tmp/x"), command: command, claudePath: nil)
        XCTAssertTrue(script.contains("exec /bin/zsh -lic \(ClaudeLauncher.shellQuote(command))"))
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(ClaudeLauncher.shellQuote("plain"), "'plain'")
        XCTAssertEqual(ClaudeLauncher.shellQuote("a'b"), "'a'\\''b'")
    }

    // MARK: - 4.4 Error taxonomy

    func testErrorHeadlinesAreCleanAndNonEmpty() {
        let cases: [ClaudeLaunchError] = [
            .claudeNotFound,
            .terminalOpenFailed(details: "NSWorkspace raw error 42"),
            .scriptWriteFailed(details: "POSIX raw error EACCES"),
        ]
        for error in cases {
            let headline = error.errorDescription ?? ""
            XCTAssertFalse(headline.isEmpty, "every case has a headline")
            XCTAssertFalse(headline.contains("raw"), "raw OS text never leaks into the headline")
        }
    }

    func testCopyableDetailsCarriesRawTextOptIn() {
        XCTAssertEqual(ClaudeLaunchError.terminalOpenFailed(details: "boom").copyableDetails, "boom")
        XCTAssertEqual(ClaudeLaunchError.scriptWriteFailed(details: "boom").copyableDetails, "boom")
        XCTAssertNil(ClaudeLaunchError.claudeNotFound.copyableDetails)
    }
}
