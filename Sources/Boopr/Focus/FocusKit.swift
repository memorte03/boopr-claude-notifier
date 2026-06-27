import AppKit
import ApplicationServices

/// Everything a `WindowRaiser` needs to bring the right OS window forward.
struct RaiseContext: Sendable {
    let req: NotifyRequest
    let pid: pid_t?
    let bundleID: String?
    /// tty to mark for OSC-2/AX/AppleScript identification: a tmux *client* tty
    /// when `multiplexed`, otherwise the session's controlling tty. nil when none
    /// was captured.
    let markTty: String?
    /// Window-title substring to match (non-multiplexer identification).
    let titleHint: String?
    /// True when a multiplexer selected the pane and `markTty` is its client tty
    /// (so the AX-marker raiser applies); false for the direct/non-tmux path
    /// (where the AX-marker raiser is unproven and we match by title instead).
    let multiplexed: Bool

    /// The terminal app: by pid when it's still running, else by bundle id.
    var app: NSRunningApplication? {
        if let pid, let a = NSRunningApplication(processIdentifier: pid) { return a }
        if let bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        }
        return nil
    }
}

/// Outcome of asking a `Multiplexer` to select a pane.
enum MuxOutcome: Sendable {
    case selected       // pane selected — proceed to raise its window
    case paneGone       // had a target but the pane is gone — non-mux fallback
    case notApplicable  // no multiplexer target — direct/non-tmux path
}

/// Inner-selection inside a multiplexer (tmux/zellij/screen) plus the permission
/// keystroke. Window raising is the `WindowRaiser` ladder's job; a multiplexer
/// only positions the pane and surfaces the client tty to mark.
protocol Multiplexer: Sendable {
    func handles(_ req: NotifyRequest) -> Bool
    func selectPane(_ req: NotifyRequest) -> MuxOutcome
    /// tty of the terminal client showing the pane's session (may retarget a
    /// client onto it). Run off-main — it shells out to the multiplexer.
    func clientTty(for req: NotifyRequest) -> String?
    @discardableResult func sendKeys(_ keys: [String], to req: NotifyRequest) -> Bool
    /// Whether the user is already looking at this pane (nil ⇒ can't tell).
    func isPaneFocused(req: NotifyRequest) -> Bool?
}

/// Raises the OS window for a focus target. The coordinator tries the registered
/// raisers in ascending `rung` order (most → least deterministic) until one
/// returns true. Each new terminal becomes a new conformer — additive.
protocol WindowRaiser: Sendable {
    var rung: Int { get }
    func canHandle(_ ctx: RaiseContext) -> Bool
    func raise(_ ctx: RaiseContext) -> Bool
}

/// AX/activation helpers shared by raisers. Moved verbatim from the old
/// `SessionFocuser` so every raiser shares one implementation; Phase 1b folds
/// the tmux `writeTitle`/`windowTitles` marker helpers in here too.
enum RaiseSupport {
    static func activate(_ app: NSRunningApplication) {
        app.activate(options: [.activateAllWindows])
    }

    static func activate(pid: pid_t?) {
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
    }

    /// Writes an OSC 2 (set window title) escape sequence directly to a tty
    /// device. This reaches the outer terminal without tmux in the way — the same
    /// mechanism tmux's own `set-titles` uses — so the AX/AppleScript window
    /// carrying the marker can be found. Shared by the Ghostty and AX-marker
    /// raisers.
    @discardableResult
    static func writeTitle(_ title: String, toTty path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Strip control bytes (incl. the OSC terminators ESC/BEL) so a restored
        // window title can't re-inject terminal escape sequences.
        let clean = String(title.unicodeScalars.filter { $0.value >= 0x20 })
        let seq = "\u{1B}]2;\(clean)\u{07}"
        let bytes = Array(seq.utf8)
        return bytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress, buf.count) == buf.count
        }
    }

    /// Raise the window whose title contains `titleSubstring`. Requires the
    /// Accessibility permission (System Settings → Privacy → Accessibility).
    static func raiseWindowByTitle(pid: pid_t, titleSubstring: String) {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success, let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            if let title = titleRef as? String, title.contains(titleSubstring) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }

    /// Identify the window showing `clientTty` by marking its title (OSC 2), then
    /// raise it and restore the title. Requires Accessibility. Runs off-main (it
    /// polls AX with short sleeps). Moved verbatim from `TmuxFocuser`.
    static func raiseWindowByMarker(appPid: pid_t, clientTty: String) {
        let axApp = AXUIElementCreateApplication(appPid)
        let before = windowTitles(axApp)

        NSLog("RaiseSupport: raising via tty \(clientTty); \(before.count) AX windows visible: \(before.map(\.title))")

        let nonce = "cn-focus-\(UUID().uuidString.prefix(8))"
        guard writeTitle(nonce, toTty: clientTty) else {
            NSLog("RaiseSupport: writing title marker to \(clientTty) failed — activating app")
            activate(pid: appPid)
            return
        }

        var marked: AXUIElement?
        for _ in 0..<8 {
            usleep(60_000)
            if let w = windowTitles(axApp).first(where: { $0.title.contains(nonce) })?.window {
                marked = w
                break
            }
        }

        guard let window = marked else {
            // Marker never surfaced. Either AX can't see the window (e.g. it
            // lives on another Space) or the terminal ignored the escape.
            NSLog("RaiseSupport: marker \(nonce) not found among AX windows \(windowTitles(axApp).map(\.title)) — activating app")
            _ = writeTitle("tmux", toTty: clientTty)
            activate(pid: appPid)
            return
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: appPid)?.activate()

        // Restore the pre-marker title — tmux won't (set-titles is usually off).
        if let original = before.first(where: { CFEqual($0.window, window) })?.title {
            _ = writeTitle(original, toTty: clientTty)
        }

        // Re-raise once the app activation settles; cheap insurance for
        // cross-Space switches.
        usleep(120_000)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private static func windowTitles(_ axApp: AXUIElement) -> [(window: AXUIElement, title: String)] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        return windows.map { w in
            var t: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (w, (t as? String) ?? "")
        }
    }
}
