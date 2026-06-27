import Foundation

enum NotifyKind: String, Codable, Sendable {
    case stop          // Claude finished
    case idle          // Claude needs input (Notification hook)
    case permission    // PreToolUse, action required
    case ask           // Claude asked a question (AskUserQuestion / ExitPlanMode)
    case info          // generic
    case error
}

/// The decoded hook payload — the central wire type the app receives over HTTP
/// (`/notify`, `/permission`) and renders in the overlay, pills, and menu.
struct NotifyRequest: Codable, Sendable, Identifiable {
    var id: String
    var kind: NotifyKind
    var repoName: String?
    var branch: String?
    var cwd: String?
    var sessionId: String?
    var title: String
    var context: String?
    var toolName: String?
    var actions: [String]?
    var terminalPid: Int?
    var terminalApp: String?
    var windowTitle: String?
    var tty: String?           // controlling pty (e.g. "/dev/ttys017") — lets the
                               // non-tmux Ghostty raiser mark + focus the exact tab
    var itermSessionId: String?  // iTerm2 session GUID (ITERM_SESSION_ID after the
                                 // colon) — native focus-by-session, no marker
    var kittyWindowId: String?   // KITTY_WINDOW_ID — kitty remote-control window id
    var kittyListenOn: String?   // KITTY_LISTEN_ON — kitty remote-control socket
    var tmuxSession: String?
    var tmuxPane: String?      // pane id, e.g. "%4" — stable for the server's lifetime
    var tmuxWindowId: String?  // tmux window id, e.g. "@2"
    var tmuxSocket: String?    // server socket path (the app may run with a bare PATH)
    var tmuxBin: String?       // absolute path to the tmux binary
    var diffPreview: String?
    /// Intentionally omitted from CodingKeys: always "now" on decode (the wire
    /// payload never carries a receipt time).
    var receivedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, kind, repoName, branch, cwd, sessionId, title, context
        case toolName, actions, terminalPid, terminalApp, windowTitle, tty
        case itermSessionId, kittyWindowId, kittyListenOn, tmuxSession
        case tmuxPane, tmuxWindowId, tmuxSocket, tmuxBin
        case diffPreview
    }
}

struct PermissionResponse: Codable, Sendable {
    let decision: String   // "allow" | "deny" | "ask"
    let reason: String?
}
