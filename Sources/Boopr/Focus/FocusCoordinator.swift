import AppKit

/// Single entry point for "bring the Claude session's surface forward" and for
/// delivering the permission keystroke. It composes the two orthogonal layers:
/// inner pane selection (`Multiplexer`) and OS window raise (`WindowRaiser`s).
///
/// A multiplexer (tmux) selects the pane and yields its client tty; otherwise the
/// session's controlling tty is used directly. Either way the same raiser ladder
/// runs off-main: Ghostty (rung 1, AppleScript — exact tab/window, cross-Space),
/// AX-marker for other multiplexed terminals (rung 3), AX-title (rung 4), and the
/// app-activation floor (rung 5).
enum FocusCoordinator {
    private static let mux: Multiplexer = TmuxMultiplexer.shared

    /// Window raisers in ascending rung order (most → least deterministic).
    private static let raisers: [WindowRaiser] = [
        GhosttyRaiser(),
        MarkerAXRaiser(),
        TitleAXRaiser(),
        AppActivationRaiser(),
    ].sorted { $0.rung < $1.rung }

    /// Raise the terminal window the session runs in (jump-to-session).
    static func focus(req: NotifyRequest) {
        let pid = req.terminalPid.map { pid_t($0) }
        let bundle = req.terminalApp

        switch mux.selectPane(req) {
        case .selected:
            // Multiplexer positioned the pane; resolve its client tty and raise
            // off-main (clientTty shells out; the raisers poll AppleScript/AX).
            DispatchQueue.global(qos: .userInitiated).async {
                let ctx = RaiseContext(
                    req: req, pid: pid, bundleID: bundle,
                    markTty: mux.clientTty(for: req), titleHint: nil, multiplexed: true
                )
                runRaisers(ctx)
            }
        case .paneGone, .notApplicable:
            // Direct path: the session's own controlling tty lets the Ghostty
            // raiser mark + focus its tab; others match by title.
            let ctx = RaiseContext(
                req: req, pid: pid, bundleID: bundle,
                markTty: req.tty, titleHint: req.windowTitle, multiplexed: false
            )
            DispatchQueue.global(qos: .userInitiated).async { runRaisers(ctx) }
        }
    }

    private static func runRaisers(_ ctx: RaiseContext) {
        for raiser in raisers where raiser.canHandle(ctx) {
            if raiser.raise(ctx) { return }
        }
    }

    /// Deliver literal keys to the session's pane (the permission 1/2 answer).
    /// Returns false when there's no deterministic multiplexer target, so the
    /// caller can fall back to focus + synthesized keystrokes.
    @discardableResult
    static func sendKeys(_ keys: [String], to req: NotifyRequest) -> Bool {
        mux.sendKeys(keys, to: req)
    }
}
