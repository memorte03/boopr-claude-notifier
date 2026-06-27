import AppKit
import ApplicationServices

/// Rung 3 (multiplexer): identify the terminal window by writing an OSC-2 marker
/// to the client tty, then AX-raise it. The proven tmux path for any terminal
/// that isn't Ghostty (Ghostty has its own rung-1 raiser). Scoped to the
/// multiplexed case — for the direct/non-tmux path we match by title instead.
struct MarkerAXRaiser: WindowRaiser {
    let rung = 3
    func canHandle(_ ctx: RaiseContext) -> Bool {
        ctx.multiplexed && ctx.markTty != nil
            && ctx.bundleID != GhosttyControl.bundleID
            && ctx.app != nil && AXIsProcessTrusted()
    }
    func raise(_ ctx: RaiseContext) -> Bool {
        guard let tty = ctx.markTty, let app = ctx.app else { return false }
        RaiseSupport.raiseWindowByMarker(appPid: app.processIdentifier, clientTty: tty)
        return true
    }
}

/// Rung 4 (direct/non-tmux): activate the terminal app and AX-raise the window
/// whose title matches. The pre-refactor `SessionFocuser` fallback,
/// behavior-for-behavior (activate, then a 0.1s-delayed title raise so the
/// app/Space switch lands first).
struct TitleAXRaiser: WindowRaiser {
    let rung = 4
    func canHandle(_ ctx: RaiseContext) -> Bool {
        !ctx.multiplexed && ctx.bundleID != GhosttyControl.bundleID
            && ctx.app != nil && ctx.titleHint != nil
    }
    func raise(_ ctx: RaiseContext) -> Bool {
        guard let app = ctx.app, let title = ctx.titleHint else { return false }
        RaiseSupport.activate(app)
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            RaiseSupport.raiseWindowByTitle(pid: pid, titleSubstring: title)
        }
        return true
    }
}

/// Rung 5: app-activation floor. Reached when we know the app but couldn't
/// identify the exact window — macOS still switches Space on activate().
struct AppActivationRaiser: WindowRaiser {
    let rung = 5
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.app != nil }
    func raise(_ ctx: RaiseContext) -> Bool {
        guard let app = ctx.app else { return false }
        RaiseSupport.activate(app)
        return true
    }
}
