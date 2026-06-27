import Foundation

/// Resolves which terminal app owns a tty by walking the process tree of the
/// processes attached to it up to a known terminal.
///
/// Needed under tmux: a pane inherits the environment of whatever started the
/// tmux *server*, not the current client's terminal — so the hook's
/// env/process-walk detection misreports (e.g. a Terminal client on a server
/// first launched from Ghostty shows `GHOSTTY_RESOURCES_DIR` and looks like
/// Ghostty). The client tty, by contrast, is genuinely owned by the right
/// terminal, so walking up from it gives the truth.
enum TerminalForTty {
    /// Bundle id of the terminal owning `tty` (e.g. "/dev/ttys028"), or nil.
    static func bundleID(forTty tty: String) -> String? {
        let dev = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard !dev.isEmpty, let out = ps(["-t", dev, "-o", "pid="]) else { return nil }
        let pids = out.split(whereSeparator: { $0 == "\n" || $0 == " " }).compactMap { Int($0) }
        for start in pids {
            var pid = start
            for _ in 0..<16 {
                guard let comm = ps(["-p", String(pid), "-o", "comm="])?.lowercased() else { break }
                if let bundle = bundle(forComm: comm) { return bundle }
                guard let ppidStr = ps(["-p", String(pid), "-o", "ppid="]),
                      let ppid = Int(ppidStr.trimmingCharacters(in: .whitespaces)),
                      ppid > 1, ppid != pid else { break }
                pid = ppid
            }
        }
        return nil
    }

    private static func bundle(forComm comm: String) -> String? {
        if comm.contains("iterm") { return "com.googlecode.iterm2" }
        if comm.contains("terminal") { return "com.apple.Terminal" }
        if comm.contains("ghostty") { return "com.mitchellh.ghostty" }
        if comm.contains("wezterm") { return "com.github.wez.wezterm" }
        if comm.contains("kitty") { return "net.kovidgoyal.kitty" }
        if comm.contains("alacritty") { return "org.alacritty" }
        return nil
    }

    private static func ps(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
