import AppKit
import ApplicationServices

/// kitty focus, driven by its remote-control protocol over a unix socket:
/// `kitten @ --to <socket> …`. Needs `allow_remote_control` + `listen_on` in
/// kitty.conf (surfaced as $KITTY_LISTEN_ON / $KITTY_WINDOW_ID). Without it we
/// fall back to raising the OS-window by tty marker.
///
/// We focus by **tty** (via `@ ls`) rather than the captured window id: the tty
/// is authoritative for both a direct session and the tmux client, and works for
/// tabs/splits — whereas $KITTY_WINDOW_ID is stale under tmux (it belongs to
/// whatever started the server). The listen socket, being a fixed path, stays
/// valid under tmux.
enum KittyControl {
    static let bundleID = "net.kovidgoyal.kitty"

    /// Focus the kitty window attached to `tty`. The control socket can be passed
    /// in (captured $KITTY_LISTEN_ON) or, when absent — e.g. under a tmux server
    /// started from a non-kitty terminal — recovered from the env of a process on
    /// that tty. Returns false when remote control is unavailable or no window
    /// matches.
    static func focusTty(_ tty: String, listenOn: String?) -> Bool {
        guard let sock = listenOn ?? discoverSocket(forTty: tty),
              let bin = kittenBinary(),
              let data = runOutput(bin, ["@", "--to", sock, "ls"]),
              let id = windowId(forTty: tty, lsJSON: data)
        else { return false }
        return run(bin, ["@", "--to", sock, "focus-window", "--match", "id:\(id)"]) == 0
    }

    /// Recover $KITTY_LISTEN_ON from the env of a process on `tty` (via `ps -E`).
    private static func discoverSocket(forTty tty: String) -> String? {
        for pid in pids(onTty: tty) {
            guard let (_, data) = exec("/bin/ps", ["-E", "-p", String(pid)]),
                  let env = String(data: data, encoding: .utf8),
                  let r = env.range(of: "KITTY_LISTEN_ON=") else { continue }
            let value = env[r.upperBound...].prefix { !$0.isWhitespace }
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    /// Focus by the captured window id — the direct fast path / fallback when no
    /// tty was captured.
    static func focusWindow(id: String, listenOn: String) -> Bool {
        guard let bin = kittenBinary() else { return false }
        return run(bin, ["@", "--to", listenOn, "focus-window", "--match", "id:\(id)"]) == 0
    }

    /// Bring kitty forward (best-effort; kitty has no AppleScript self-activate).
    @discardableResult
    static func activate() -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// Find the kitty window for `tty` by correlating pids: `@ ls` reports each
    /// window's launched `pid` and `foreground_processes` (e.g. the tmux client),
    /// and those processes live on the target tty. kitty's `ls` has no tty field,
    /// so this is the bridge.
    private static func windowId(forTty tty: String, lsJSON data: Data) -> String? {
        let onTty = pids(onTty: tty)
        guard !onTty.isEmpty,
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for osw in osWindows {
            for tab in (osw["tabs"] as? [[String: Any]] ?? []) {
                for w in (tab["windows"] as? [[String: Any]] ?? []) {
                    var wpids: [Int] = []
                    if let p = w["pid"] as? Int { wpids.append(p) }
                    for fp in (w["foreground_processes"] as? [[String: Any]] ?? []) {
                        if let p = fp["pid"] as? Int { wpids.append(p) }
                    }
                    if wpids.contains(where: onTty.contains), let id = w["id"] as? Int {
                        return String(id)
                    }
                }
            }
        }
        return nil
    }

    /// Pids whose controlling terminal is `tty`.
    private static func pids(onTty tty: String) -> Set<Int> {
        let dev = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard !dev.isEmpty, let (status, data) = exec("/bin/ps", ["-t", dev, "-o", "pid="]),
              status == 0, let out = String(data: data, encoding: .utf8) else { return [] }
        return Set(out.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { Int($0) })
    }

    /// The `kitten` remote-control client — from the app bundle first, then PATH.
    private static func kittenBinary() -> String? {
        let fm = FileManager.default
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let p = appURL.appendingPathComponent("Contents/MacOS/kitten").path
            if fm.isExecutableFile(atPath: p) { return p }
        }
        for p in ["/Applications/kitty.app/Contents/MacOS/kitten",
                  "/opt/homebrew/bin/kitten", "/usr/local/bin/kitten"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        guard let (status, _) = exec(path, args) else { return -1 }
        return status
    }

    private static func runOutput(_ path: String, _ args: [String]) -> Data? {
        guard let (status, data) = exec(path, args), status == 0 else { return nil }
        return data
    }

    /// Run with a short timeout so a dead control socket can't hang the jump.
    private static func exec(_ path: String, _ args: [String]) -> (Int32, Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do { try p.run() } catch { return nil }
        if sem.wait(timeout: .now() + 2) == .timedOut { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, data)
    }
}

/// Rung 1: kitty. Exact window focus by tty via remote control (direct + tmux,
/// tabs/splits); otherwise raise the right OS-window by marking its tty.
struct KittyRaiser: WindowRaiser {
    let rung = 1
    func canHandle(_ ctx: RaiseContext) -> Bool { ctx.bundleID == KittyControl.bundleID }
    func raise(_ ctx: RaiseContext) -> Bool {
        // Exact focus by tty (direct + tmux, tabs/splits). The control socket is
        // the captured $KITTY_LISTEN_ON, or recovered from the client tty's env
        // when absent (tmux server started from a non-kitty terminal).
        if let tty = ctx.markTty, KittyControl.focusTty(tty, listenOn: ctx.req.kittyListenOn) {
            KittyControl.activate(); return true
        }
        // No tty / remote control failed: the captured window id (direct only).
        if !ctx.multiplexed, let id = ctx.req.kittyWindowId, let sock = ctx.req.kittyListenOn,
           KittyControl.focusWindow(id: id, listenOn: sock) {
            KittyControl.activate(); return true
        }
        // No remote control: raise the OS-window by marking its tty.
        if let tty = ctx.markTty, let app = ctx.app, AXIsProcessTrusted() {
            RaiseSupport.raiseWindowByMarker(appPid: app.processIdentifier, clientTty: tty)
            return true
        }
        if let app = ctx.app { RaiseSupport.activate(app); return true }
        return false
    }
}
