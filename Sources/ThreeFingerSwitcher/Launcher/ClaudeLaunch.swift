import Foundation

/// Open-Claude-Here support: resolve the `claude` executable, build the terminal-handoff script, and
/// classify failures — the pieces a `.claudeProject` item needs to launch Claude Code in the user's
/// default terminal **without a new permission**.
///
/// The handoff deliberately does NOT script Terminal.app via AppleScript (that would prompt for an
/// Automation/Apple-Events grant and pin us to one terminal). Instead it writes a self-deleting,
/// executable `.command` file and opens it with the system default handler — so it uses whatever
/// terminal the user has set as default. The `.command` runs in a real terminal window (a TTY + the
/// user's shell PATH), which the app's headless `.script` runner (`/bin/zsh -c`) can't provide and
/// which Claude (an interactive TUI) requires.

/// A small Core error taxonomy for the Open-Claude-Here flow, parallel to `FileActionError`:
/// `LocalizedError` with a clean, per-case, user-facing headline for every case (never a reflected
/// enum dump or raw OS text). Vendor/OS errors are stringified into the opt-in `copyableDetails`
/// payload at the boundary (a `String?`, kept `Equatable`) — surfaced only as a "Show details / Copy"
/// disclosure and in logs, never as the headline.
enum ClaudeLaunchError: Error, Equatable {
    /// The `claude` command could not be found on this Mac (not installed, or not on any resolvable PATH).
    case claudeNotFound
    /// The default terminal could not be opened to start Claude. `details` is opt-in copyable text.
    case terminalOpenFailed(details: String?)
    /// The temporary launch script could not be written. `details` is opt-in copyable text (raw OS error).
    case scriptWriteFailed(details: String?)
}

extension ClaudeLaunchError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Couldn't find the “claude” command. Install Claude Code, then try again."
        case .terminalOpenFailed:
            return "Couldn't open your terminal to start Claude."
        case .scriptWriteFailed:
            return "Couldn't prepare the Claude launch. Please try again."
        }
    }

    /// The opt-in copyable detail (raw error text captured at the boundary), for a "Show details / Copy"
    /// disclosure and logs only. `nil` when the headline already says everything.
    var copyableDetails: String? {
        switch self {
        case .claudeNotFound: return nil
        case let .terminalOpenFailed(details): return details
        case let .scriptWriteFailed(details): return details
        }
    }
}

/// Pure builders + the (process-spawning) resolver for the Claude terminal handoff. The script builder
/// is pure and unit-tested; the resolver spawns a shell and so must be called off the main thread.
enum ClaudeLauncher {

    // MARK: - Script (pure, unit-tested)

    /// Single-quote a string for safe inclusion in a `/bin/zsh` script (handles spaces and quotes).
    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The contents of the self-deleting `.command` launch script. After `cd`-ing into `folder`, it runs
    /// the *inner* command through an interactive **login** shell (`zsh -lic`) so the user's shell-profile
    /// PATH (nvm/fnm/homebrew, in `.zprofile`/`.zshrc`) applies — Claude's own `#!/usr/bin/env node`
    /// shebang needs `node` on PATH, so a bare `exec` of even an absolute `claude` path would fail for an
    /// npm install. The inner command is, in order: a non-empty custom `command` run as written; else the
    /// resolved `claudePath` `exec`'d by absolute path (runs the exact validated binary even if `claude`
    /// isn't on PATH); else `claude` from PATH. The first line removes the script itself (the shell has
    /// already read it) so no artifact is left on disk.
    nonisolated static func commandScript(folder: URL, command: String?, claudePath: String?) -> String {
        let trimmedCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inner: String
        if !trimmedCommand.isEmpty {
            inner = trimmedCommand
        } else if let claudePath, !claudePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inner = "exec \(shellQuote(claudePath))"
        } else {
            inner = "claude"
        }
        return """
        #!/bin/zsh
        rm -f "$0"
        cd \(shellQuote(folder.path)) || exit 1
        exec /bin/zsh -lic \(shellQuote(inner))
        """
    }

    /// Write the launch script to a unique temp `.command` file and mark it executable. Throws
    /// `ClaudeLaunchError.scriptWriteFailed` (raw error in the opt-in details) on any IO failure.
    static func writeCommandFile(folder: URL, command: String?, claudePath: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-launch-\(UUID().uuidString).command")
        do {
            try commandScript(folder: folder, command: command, claudePath: claudePath).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            throw ClaudeLaunchError.scriptWriteFailed(details: String(describing: error))
        }
    }

    // MARK: - Item factory

    /// The default appearance for a freshly-added Claude Project item: titled with the folder's name and
    /// a `sparkles` glyph. Centralized (in Core) so the editor's add flow and tests agree on the default.
    nonisolated static func makeItem(folder: URL, claudePath: String?) -> LaunchItem {
        LaunchItem(title: folder.lastPathComponent, icon: .sfSymbol("sparkles"),
                   kind: .claudeProject(folder: folder, claudePath: claudePath))
    }

    /// The default appearance for a freshly-added **choose-folder-at-launch** Claude item: a `sparkles`
    /// glyph and a generic title — it has no folder to name itself after (the folder is picked each run).
    nonisolated static func makePromptItem(claudePath: String?) -> LaunchItem {
        LaunchItem(title: "Claude (Pick Folder)", icon: .sfSymbol("sparkles"),
                   kind: .claudeProjectPrompt(claudePath: claudePath))
    }

    // MARK: - Resolution (spawns a shell — call OFF the main thread)

    /// Resolve the absolute path to `claude`, or `nil` if it can't be found. Tries an interactive login
    /// shell first (so the user's full profile PATH applies, covering version managers and homebrew),
    /// then a short list of well-known install locations as a backstop against shell-config quirks.
    static func resolveClaudePath() -> String? {
        if let viaShell = resolveViaLoginShell() { return viaShell }
        let fm = FileManager.default
        return knownInstallPaths().first { fm.isExecutableFile(atPath: $0) }
    }

    /// `claude` locations to probe when the shell lookup comes up empty: the native installer
    /// (`~/.local/bin`, `~/.claude/local`), homebrew (Apple-silicon + Intel prefixes), and a common
    /// npm-global prefix.
    private static func knownInstallPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
    }

    /// Ask an interactive login shell for `command -v claude`. Accepts only an absolute path to a real
    /// executable (a shell function/alias prints non-path text → rejected). A watchdog terminates a
    /// profile that hangs so this never blocks indefinitely.
    private static func resolveViaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()   // discard job-control / profile noise
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Take the last path-like line (a profile may echo noise to stdout before the answer).
        let path = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
