import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The side-effecting spawn seam (`ai-claude-handoff`, design Decision 3 / 7). Behind a protocol so the
/// contributor is headless-testable: `swift test` drives a FAKE launcher that records `(folder, prompt)`
/// without spawning anything; the production `OpenClaudeHandoffLauncher` does the real `.command` +
/// `NSWorkspace.open` handoff. Fire-and-forget v1: `launch` opens Claude and returns; it throws a mapped
/// `HandoffError` if it can't open. MLX-free Core.
protocol HandoffLauncher: Sendable {
    func launch(folder: URL, prompt: String) async throws
}

/// The production adapter (`ai-claude-handoff`, design Decision 7) — the ONLY side-effecting code in the
/// slice. It composes the EXISTING open-claude-here launch path (`ClaudeLauncher.shellQuote`/
/// `resolveClaudePath`/`writeCommandFile` + `NSWorkspace.shared.open`) byte-for-byte — NO new launch
/// mechanism, NO new permission (no Apple Events). A non-empty prompt becomes the inner command
/// `claude '<prompt>'`; an empty prompt opens a bare `claude` session. Off-main resolution + write,
/// main-actor open, success-needs-no-notification (the terminal window is its own feedback). Failures map
/// at this boundary into `HandoffError.launchFailed` (the existing clean `ClaudeLaunchError` headline
/// flows through). `Launcher/ClaudeLaunch.swift` is UNCHANGED by this slice; this only CALLS its builders.
struct OpenClaudeHandoffLauncher: HandoffLauncher {

    init() {}

    /// Build the inner command for a starting prompt: empty → nil (bare `claude` via the script default);
    /// else `claude '<shell-quoted prompt>'` (the prompt passed as Claude's argument, exactly how a custom
    /// `command` rides `ClaudeLauncher.commandScript`'s inner-command slot). Pure + unit-tested.
    static func innerCommand(forPrompt prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "claude \(ClaudeLauncher.shellQuote(prompt))"
    }

    func launch(folder: URL, prompt: String) async throws {
        let inner = Self.innerCommand(forPrompt: prompt)
        // Off-main: a bare session resolves the absolute claude path (so a non-PATH install still runs);
        // a prompt session lets the script's `claude`-from-PATH carry it (the inner command is `claude …`).
        let claudePath = inner == nil ? ClaudeLauncher.resolveClaudePath() : nil
        let url: URL
        do {
            url = try ClaudeLauncher.writeCommandFile(folder: folder, command: inner, claudePath: claudePath)
        } catch let e as ClaudeLaunchError {
            throw Self.map(e)
        } catch {
            throw HandoffError.launchFailed(headline: ClaudeLaunchError.scriptWriteFailed(details: nil).errorDescription
                                                ?? "Couldn't prepare the Claude launch. Please try again.",
                                            details: String(describing: error))
        }

        #if canImport(AppKit)
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        if !opened {
            throw Self.map(.terminalOpenFailed(details: "NSWorkspace.open returned false for \(url.lastPathComponent)"))
        }
        #endif
    }

    /// Map a `ClaudeLaunchError` into `HandoffError.launchFailed` at the launch boundary — the clean
    /// headline flows through; raw OS/vendor text rides only in `details`.
    static func map(_ e: ClaudeLaunchError) -> HandoffError {
        .launchFailed(headline: e.errorDescription ?? "Couldn't open Claude Code.",
                      details: e.copyableDetails)
    }
}
