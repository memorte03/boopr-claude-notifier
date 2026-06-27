import AppKit

/// iTerm2 native focus. iTerm2 exports `ITERM_SESSION_ID` as `wNtNpN:<GUID>`,
/// and that GUID is the AppleScript `id of session` — so we can select the exact
/// session/tab/window and activate (cross-Space) without a tty marker or AX.
enum ITerm2Control {
    static let bundleID = "com.googlecode.iterm2"

    /// Select the session with the given GUID and bring iTerm2 forward. Returns
    /// false if no session matches (stale id) or Automation is denied.
    static func focusSession(_ id: String) -> Bool {
        // GUIDs don't contain quotes; strip any defensively so the id can't break
        // out of the string literal.
        let safe = id.replacingOccurrences(of: "\"", with: "")
        let script = """
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if id of s is "\(safe)" then
                            select s
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """
        return AppleScript.run(script) == "ok"
    }

    /// Select the session attached to `tty` and bring iTerm2 forward. Works for
    /// both a direct session (its controlling tty) and tmux running in iTerm (the
    /// tmux client tty) — `tty of session` matches either, and selecting handles
    /// tabs/splits where the AX-marker path can't.
    static func focusTty(_ tty: String) -> Bool {
        let safe = tty.replacingOccurrences(of: "\"", with: "")
        let script = """
        tell application id "\(bundleID)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(safe)" then
                            select s
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return ""
        """
        return AppleScript.run(script) == "ok"
    }

    /// Bring iTerm2 forward without targeting a session (self-activation).
    static func activate() -> Bool {
        AppleScript.runVoid("tell application id \"\(bundleID)\" to activate")
    }
}

/// Rung 1: iTerm2 via AppleScript — selects the exact session/tab/window and
/// activates (cross-Space). Handles both the direct case and tmux-in-iTerm:
/// prefer the tty (authoritative for the tmux client *and* a direct session),
/// fall back to the session GUID (direct only), then a plain activate.
struct ITerm2Raiser: WindowRaiser {
    let rung = 1
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.bundleID == ITerm2Control.bundleID }
    func raise(_ ctx: RaiseContext) -> Bool {
        if let tty = ctx.markTty, ITerm2Control.focusTty(tty) { return true }
        if !ctx.multiplexed, let id = ctx.req.itermSessionId, ITerm2Control.focusSession(id) { return true }
        return ITerm2Control.activate()
    }
}
