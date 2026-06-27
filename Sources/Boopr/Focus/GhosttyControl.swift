import AppKit

/// Drives Ghostty's AppleScript interface (1.3+) to focus a specific terminal
/// tab across Spaces, or to bring the app forward. Self-activation via Apple
/// Events works where `NSRunningApplication.activate()` — cooperative cross-app
/// activation from a background agent — silently fails on macOS 14+. Moved out of
/// `TmuxFocuser` so both the tmux client-tty path and the non-tmux
/// controlling-tty path share it.
enum GhosttyControl {
    static let bundleID = "com.mitchellh.ghostty"

    /// Identify the Ghostty tab showing `tty` by writing a title marker to it,
    /// then find + focus it natively and restore the original title. Returns
    /// false on pre-1.3 Ghostty, denied Automation, or when the marker can't be
    /// found (e.g. the terminal re-titled before we polled). Must run off the
    /// main thread (it polls with `usleep`).
    static func focusTab(tty: String) -> Bool {
        let before = terminals()
        guard !before.isEmpty else { return false }

        let nonce = "cn-focus-\(UUID().uuidString.prefix(8))"
        guard RaiseSupport.writeTitle(nonce, toTty: tty) else { return false }

        var focusedID: String?
        for _ in 0..<8 {
            usleep(60_000)
            if let id = focusMarked(nonce) { focusedID = id; break }
        }

        guard let id = focusedID else {
            // Marker stuck on a title we couldn't find; overwrite with something
            // sane (the shell/Claude will re-title shortly anyway).
            _ = RaiseSupport.writeTitle("tmux", toTty: tty)
            NSLog("GhosttyControl: marker \(nonce) not found")
            return false
        }
        if let original = before.first(where: { $0.id == id })?.name {
            _ = RaiseSupport.writeTitle(original, toTty: tty)
        }
        NSLog("GhosttyControl: focused terminal \(id) (tty \(tty))")
        return true
    }

    /// Bring Ghostty forward without targeting a specific tab (self-activation,
    /// crosses Spaces). The non-tmux fallback when there's no usable tty.
    static func activate() -> Bool {
        AppleScript.runVoid("tell application id \"\(bundleID)\" to activate")
    }

    /// (id, title) of every Ghostty terminal across all windows and Spaces.
    /// Empty on pre-1.3 Ghostty or when Automation permission is denied.
    private static func terminals() -> [(id: String, name: String)] {
        let script = """
        tell application id "com.mitchellh.ghostty"
            set out to ""
            repeat with i from 1 to (count of terminals)
                set t to terminal i
                set out to out & (get id of t) & "\u{1F}" & (get name of t) & linefeed
            end repeat
            return out
        end tell
        """
        guard let out = AppleScript.run(script) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 2 else { return nil }
            return (parts[0], parts[1])
        }
    }

    /// Focus the Ghostty terminal whose title contains `marker`; returns its
    /// stable id, or nil when nothing matches (yet).
    private static func focusMarked(_ marker: String) -> String? {
        let script = """
        tell application id "com.mitchellh.ghostty"
            repeat with i from 1 to (count of terminals)
                set t to terminal i
                if (get name of t) contains "\(marker)" then
                    focus t
                    activate
                    return get id of t
                end if
            end repeat
        end tell
        return ""
        """
        guard let out = AppleScript.run(script), !out.isEmpty else { return nil }
        return out
    }
}

/// Rung 1: Ghostty via its AppleScript interface — focuses the exact tab when we
/// have a tty to mark, else brings the app forward. Both cross Spaces, unlike the
/// AX/`NSRunningApplication` fallbacks.
struct GhosttyRaiser: WindowRaiser {
    let rung = 1
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.bundleID == GhosttyControl.bundleID }
    func raise(_ ctx: RaiseContext) -> Bool {
        if let tty = ctx.markTty, GhosttyControl.focusTab(tty: tty) { return true }
        return GhosttyControl.activate()
    }
}
