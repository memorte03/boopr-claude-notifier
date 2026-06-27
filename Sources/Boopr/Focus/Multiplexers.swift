import AppKit
import Foundation

/// tmux as a `Multiplexer`: it selects the exact pane a Claude session runs in
/// and resolves the tty of the terminal client showing it. Bringing that
/// client's window forward is the `WindowRaiser` ladder's job — this type no
/// longer raises windows itself (that was the conflation the refactor removed).
///
/// Selection (`select-window`/`select-pane`) and key delivery need no
/// permissions; `clientTty` may retarget a client onto the session.
struct TmuxMultiplexer: Multiplexer {
    static let shared = TmuxMultiplexer()

    struct Target: Sendable {
        let bin: String
        let socket: String
        let pane: String
    }

    func target(from req: NotifyRequest) -> Target? {
        guard let bin = req.tmuxBin, !bin.isEmpty,
              let socket = req.tmuxSocket, !socket.isEmpty,
              let pane = req.tmuxPane, !pane.isEmpty
        else { return nil }
        return Target(bin: bin, socket: socket, pane: pane)
    }

    func handles(_ req: NotifyRequest) -> Bool { target(from: req) != nil }

    func selectPane(_ req: NotifyRequest) -> MuxOutcome {
        guard let t = target(from: req) else { return .notApplicable }
        guard paneSession(t) != nil else { return .paneGone }
        // `-t <pane>` on select-window resolves to the window containing the pane.
        tmux(t, "select-window", "-t", t.pane)
        tmux(t, "select-pane", "-t", t.pane)
        return .selected
    }

    func clientTty(for req: NotifyRequest) -> String? {
        guard let t = target(from: req), let session = paneSession(t) else { return nil }
        return clientTty(t, session: session)
    }

    /// Sends literal keys (e.g. ["1", "Enter"]) straight to the captured pane —
    /// no focus, no Accessibility, no window switching. Returns false if the pane
    /// is gone so the caller can fall back.
    @discardableResult
    func sendKeys(_ keys: [String], to req: NotifyRequest) -> Bool {
        guard let t = target(from: req), paneSession(t) != nil else { return false }
        return tmux(t, ["send-keys", "-t", t.pane] + keys) != nil
    }

    /// Deterministic "is the user already looking at this pane" check: the pane
    /// must be the active pane of the active window of its session, and a client
    /// attached to that session must report OS focus (tmux tracks terminal
    /// focus-in/out per client). Returns nil when the request has no tmux
    /// identity or the pane is gone — caller falls back to heuristics.
    func isPaneFocused(req: NotifyRequest) -> Bool? {
        guard let t = target(from: req) else { return nil }
        guard let active = tmux(t, "display-message", "-p", "-t", t.pane,
                                "#{?#{&&:#{pane_active},#{window_active}},1,0}"),
              let session = paneSession(t)
        else { return nil }
        if active != "1" { return false }

        guard let out = tmux(t, "list-clients", "-F",
                             "#{client_session}\u{1F}#{client_flags}") else { return false }
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{1F}")
            if parts.count >= 2, parts[0] == session, parts[1].contains("focused") {
                return true
            }
        }
        return false
    }

    // MARK: - tmux plumbing

    /// Session currently containing the pane (nil ⇒ pane is gone).
    private func paneSession(_ t: Target) -> String? {
        guard let out = tmux(t, "display-message", "-p", "-t", t.pane, "#{session_name}"),
              !out.isEmpty else { return nil }
        return out
    }

    /// tty of the client displaying `session`. If none, retargets the most
    /// recently active client to the session and returns its tty.
    private func clientTty(_ t: Target, session: String) -> String? {
        guard let out = tmux(t, "list-clients", "-F",
                             "#{client_tty}\u{1F}#{client_session}\u{1F}#{client_activity}")
        else { return nil }
        var newest: (tty: String, activity: Int)?
        for line in out.split(separator: "\n") {
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count >= 3 else { continue }
            if parts[1] == session { return parts[0] }
            let activity = Int(parts[2]) ?? 0
            if newest == nil || activity > newest!.activity {
                newest = (parts[0], activity)
            }
        }
        guard let newest else { return nil }
        // Side effect: no client is showing this session, so we retarget the
        // most-recently-active client onto it — that terminal window is moved
        // off whatever session it was displaying. Expected for "jump", but note
        // it changes what isPaneFocused/the watcher observe for that client.
        guard tmux(t, "switch-client", "-c", newest.tty, "-t", session) != nil else { return nil }
        return newest.tty
    }

    @discardableResult
    private func tmux(_ t: Target, _ args: String...) -> String? {
        tmux(t, args)
    }

    @discardableResult
    private func tmux(_ t: Target, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: t.bin)
        p.arguments = ["-S", t.socket] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            NSLog("TmuxMultiplexer: failed to run tmux: \(error)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
