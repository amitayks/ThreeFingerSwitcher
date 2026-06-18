import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the general "Open in Terminal" item (`.terminalCommand`): default appearance, the pure
/// `.command` script builder (including the blank-command "just open a shell" case), Codable
/// round-trip, and the `TerminalLaunchError` taxonomy.
final class TerminalLaunchTests: XCTestCase {

    func testMakeItemDefaultAppearance() {
        let folder = URL(fileURLWithPath: "/Users/me/keisar/loop")
        let item = TerminalLauncher.makeItem(folder: folder, command: "npm run dev")
        XCTAssertEqual(item.title, "loop")
        XCTAssertEqual(item.icon, .sfSymbol("terminal"))
        XCTAssertTrue(item.isConsequential)
        guard case let .terminalCommand(f, c) = item.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(f, folder)
        XCTAssertEqual(c, "npm run dev")
    }

    func testCommandScriptRunsTheCommand() {
        let script = TerminalLauncher.commandScript(folder: URL(fileURLWithPath: "/Users/me/keisar/loop"),
                                                    command: "npm run dev")
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh"))
        XCTAssertTrue(script.contains("rm -f \"$0\""))
        XCTAssertTrue(script.contains("cd '/Users/me/keisar/loop'"))
        XCTAssertTrue(script.contains("exec /bin/zsh -lic 'npm run dev'"))
    }

    func testCommandScriptBlankCommandOpensShell() {
        let script = TerminalLauncher.commandScript(folder: URL(fileURLWithPath: "/tmp/x"), command: "   ")
        XCTAssertTrue(script.contains("cd '/tmp/x'"))
        XCTAssertTrue(script.contains("exec /bin/zsh -il"))     // interactive shell, no -c
        XCTAssertFalse(script.contains("-lic"))                 // not running a command
    }

    func testCommandScriptEscapesQuotes() {
        let command = "echo 'hi there' && make"
        let script = TerminalLauncher.commandScript(folder: URL(fileURLWithPath: "/tmp/x"), command: command)
        XCTAssertTrue(script.contains("exec /bin/zsh -lic \(ClaudeLauncher.shellQuote(command))"))
    }

    func testCodableRoundTrip() throws {
        let item = TerminalLauncher.makeItem(folder: URL(fileURLWithPath: "/tmp/Repo"), command: "make build")
        let decoded = try JSONDecoder().decode(LaunchItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        guard case let .terminalCommand(_, command) = decoded.kind else { return XCTFail("wrong kind") }
        XCTAssertEqual(command, "make build")
    }

    func testErrorHeadlinesAreCleanAndNonEmpty() {
        let cases: [TerminalLaunchError] = [.terminalOpenFailed(details: "raw 42"), .scriptWriteFailed(details: "raw EACCES")]
        for error in cases {
            let headline = error.errorDescription ?? ""
            XCTAssertFalse(headline.isEmpty)
            XCTAssertFalse(headline.contains("raw"))
        }
        XCTAssertEqual(TerminalLaunchError.scriptWriteFailed(details: "boom").copyableDetails, "boom")
    }
}
