import Foundation

/// Support for the general "Open in Terminal" item (`.terminalCommand`): the sibling of the Claude
/// Project that runs ANY command in the user's default terminal at a folder, with the same
/// no-new-permission `.command` handoff but none of the claude-specific resolution/validation.
///
/// It reuses `ClaudeLauncher.shellQuote` for safe quoting. The only real difference from the Claude
/// path is the inner command: a non-empty command is run through a login+interactive shell (so the
/// user's PATH resolves `npm`/`node`/etc.); an empty command drops into an interactive shell in the
/// folder ("just open a terminal here").

/// Error taxonomy for the general terminal launch — parallel to `ClaudeLaunchError`, minus the
/// claude-not-found case (there is no binary to validate). `LocalizedError` with clean per-case
/// headlines; raw OS text rides only in the opt-in `copyableDetails`.
enum TerminalLaunchError: Error, Equatable {
    case terminalOpenFailed(details: String?)
    case scriptWriteFailed(details: String?)
}

extension TerminalLaunchError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .terminalOpenFailed: return "Couldn't open your terminal."
        case .scriptWriteFailed:  return "Couldn't prepare the terminal launch. Please try again."
        }
    }

    var copyableDetails: String? {
        switch self {
        case let .terminalOpenFailed(details): return details
        case let .scriptWriteFailed(details):  return details
        }
    }
}

enum TerminalLauncher {

    /// The default appearance for a freshly-added Open-in-Terminal item: titled with the folder's name
    /// and a `terminal` glyph.
    nonisolated static func makeItem(folder: URL, command: String) -> LaunchItem {
        LaunchItem(title: folder.lastPathComponent, icon: .sfSymbol("terminal"),
                   kind: .terminalCommand(folder: folder, command: command))
    }

    /// The self-deleting `.command` script: `cd` into `folder`, then run `command` through a login+
    /// interactive shell (so the user's profile PATH applies). An **empty** command drops into an
    /// interactive login shell in the folder instead of running anything. The first line removes the
    /// script itself (already read by the shell) so nothing is left on disk.
    nonisolated static func commandScript(folder: URL, command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let launch = trimmed.isEmpty
            ? "exec /bin/zsh -il"
            : "exec /bin/zsh -lic \(ClaudeLauncher.shellQuote(trimmed))"
        return """
        #!/bin/zsh
        rm -f "$0"
        cd \(ClaudeLauncher.shellQuote(folder.path)) || exit 1
        \(launch)
        """
    }

    /// Write the launch script to a unique temp `.command` file and mark it executable. Throws
    /// `TerminalLaunchError.scriptWriteFailed` (raw error in the opt-in details) on any IO failure.
    static func writeCommandFile(folder: URL, command: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-launch-\(UUID().uuidString).command")
        do {
            try commandScript(folder: folder, command: command).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            throw TerminalLaunchError.scriptWriteFailed(details: String(describing: error))
        }
    }
}
