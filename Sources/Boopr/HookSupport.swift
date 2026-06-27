import Foundation

/// Helpers shared by the hook CLI (`Boopr __hook …`). These port what the old
/// bash `boopr-common.sh` did with jq/git/tmux/ps — but in-process, so the
/// shipped app needs no external `jq`.

// MARK: - subprocess + PATH resolution

enum Proc {
    /// Resolve an executable by name across $PATH plus the usual macOS dirs.
    /// Absolute inputs are returned as-is when executable.
    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        // The hook usually inherits Claude's PATH, but append the common dirs
        // so git/tmux still resolve under a sparse environment.
        dirs += ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs where !d.isEmpty {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Run a command and capture stdout. Never throws; returns ("", -1) on any
    /// failure so a missing binary can't abort the hook.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (out: String, code: Int32) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return ("", -1) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
}

// MARK: - the Claude Code hook payload (stdin)

/// Thin reader over Claude's hook JSON. `tool_input` is tool-specific, so we
/// keep the parsed dictionary rather than fighting Codable over heterogeneous
/// shapes.
struct HookInput {
    let dict: [String: Any]

    init(_ raw: Data) {
        dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    }

    func str(_ key: String) -> String { dict[key] as? String ?? "" }

    var cwd: String { str("cwd") }
    var sessionId: String { str("session_id") }
    var toolName: String { str("tool_name") }
    var message: String { str("message") }
    var event: String { str("hook_event_name") }

    var toolInput: [String: Any] { dict["tool_input"] as? [String: Any] ?? [:] }

    /// A `tool_input` sub-field as a string (mirrors jq `// empty`).
    func ti(_ key: String) -> String { toolInput[key] as? String ?? "" }

    /// First non-empty of several `tool_input` keys (jq `.a // .b // empty`).
    func tiAny(_ keys: String...) -> String {
        for k in keys { if let v = toolInput[k] as? String, !v.isEmpty { return v } }
        return ""
    }

    /// Compact JSON of `tool_input` for the generic-tool context (jq `tostring`).
    var toolInputString: String {
        guard !toolInput.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: toolInput) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - environment-derived context (terminal, git, tmux)

enum HookContext {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func trim(_ s: String, max: Int = 180) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    /// basename with a fallback so an empty path doesn't render as ".".
    static func basename(_ path: String) -> String {
        path.isEmpty ? "file" : (path as NSString).lastPathComponent
    }

    static func uuid() -> String { UUID().uuidString.lowercased() }

    static func repoName(cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        if let git = Proc.which("git") {
            let r = Proc.run(git, ["-C", cwd, "rev-parse", "--show-toplevel"])
            let top = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.code == 0, !top.isEmpty { return (top as NSString).lastPathComponent }
        }
        return (cwd as NSString).lastPathComponent
    }

    static func branch(cwd: String) -> String {
        guard !cwd.isEmpty, let git = Proc.which("git") else { return "" }
        let r = Proc.run(git, ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])
        return r.code == 0 ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    /// Identify the terminal hosting this hook: (pid, bundle id, window title,
    /// controlling tty). Bundle id from env fingerprints first (these survive
    /// tmux/screen), then a walk up the process tree. PID and tty are
    /// best-effort: the hook itself is often spawned detached (no controlling
    /// terminal), so the tty is recovered from the first ancestor that still owns
    /// one (the shell that launched Claude). Used to mark + focus the exact
    /// terminal tab in the non-tmux case.
    static func terminalInfo() -> (pid: String, app: String, title: String, tty: String) {
        func envSet(_ keys: String...) -> Bool { keys.contains { !(env[$0] ?? "").isEmpty } }

        var bundleId = ""
        if envSet("GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR") {
            bundleId = "com.mitchellh.ghostty"
        } else if envSet("ITERM_PROFILE", "ITERM_SESSION_ID") || env["TERM_PROGRAM"] == "iTerm.app" {
            bundleId = "com.googlecode.iterm2"
        } else if env["TERM_PROGRAM"] == "Apple_Terminal" {
            bundleId = "com.apple.Terminal"
        } else if env["TERM_PROGRAM"] == "WezTerm" {
            bundleId = "com.github.wez.wezterm"
        } else if env["TERM_PROGRAM"] == "vscode" {
            bundleId = "com.microsoft.VSCode"
        } else if !(env["KITTY_WINDOW_ID"] ?? "").isEmpty || (env["TERM"] ?? "").contains("kitty") {
            bundleId = "net.kovidgoyal.kitty"
        } else if envSet("ALACRITTY_LOG", "ALACRITTY_SOCKET") {
            bundleId = "org.alacritty"
        }

        var termPid = ""
        var controllingTty = ""
        let ps = "/bin/ps"
        var pid = Int(getppid())
        while pid > 1 {
            // Recover the controlling tty from the first ancestor that still owns
            // one (the hook is usually detached). "??" means no controlling tty.
            if controllingTty.isEmpty {
                let t = Proc.run(ps, ["-p", String(pid), "-o", "tty="]).out
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !t.hasPrefix("?") { controllingTty = "/dev/" + t }
            }
            let comm = Proc.run(ps, ["-p", String(pid), "-o", "comm="]).out
                .replacingOccurrences(of: " ", with: "")
            let lower = comm.lowercased()
            func hit(_ fallback: String) { termPid = String(pid); if bundleId.isEmpty { bundleId = fallback } }
            if lower.contains("iterm") { hit("com.googlecode.iterm2"); break }
            else if lower.contains("terminal") { hit("com.apple.Terminal"); break }
            else if lower.contains("alacritty") { hit("org.alacritty"); break }
            else if lower.contains("kitty") { hit("net.kovidgoyal.kitty"); break }
            else if lower.contains("wezterm") { hit("com.github.wez.wezterm"); break }
            else if lower.contains("ghostty") { hit("com.mitchellh.ghostty"); break }
            else if lower.contains("code") { hit("com.microsoft.VSCode"); break }
            guard let ppid = Int(Proc.run(ps, ["-p", String(pid), "-o", "ppid="]).out
                .trimmingCharacters(in: .whitespaces)), ppid != pid else { break }
            pid = ppid
        }

        var title = env["ITERM_SESSION_ID"] ?? ""
        if title.isEmpty, let pwd = env["PWD"], !pwd.isEmpty { title = (pwd as NSString).lastPathComponent }
        return (termPid, bundleId, title, controllingTty)
    }

    /// iTerm2 session GUID from `ITERM_SESSION_ID` (format `wNtNpN:<GUID>`) — the
    /// part after the last colon, which is iTerm2's AppleScript `id of session`.
    /// Empty when not under iTerm2.
    static func itermSessionId() -> String {
        let raw = env["ITERM_SESSION_ID"] ?? ""
        if let colon = raw.lastIndex(of: ":") { return String(raw[raw.index(after: colon)...]) }
        return raw
    }

    /// tmux identity: (session, pane, window id, socket, binary path).
    static func tmuxInfo() -> (session: String, pane: String, window: String, socket: String, bin: String) {
        guard let tmuxEnv = env["TMUX"], !tmuxEnv.isEmpty, let tmux = Proc.which("tmux") else {
            return ("", "", "", "", "")
        }
        let socket = String(tmuxEnv.split(separator: ",", maxSplits: 1).first ?? "")
        let pane = env["TMUX_PANE"] ?? ""
        var session = "", window = ""
        if !pane.isEmpty {
            session = Proc.run(tmux, ["display-message", "-p", "-t", pane, "#{session_name}"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            window = Proc.run(tmux, ["display-message", "-p", "-t", pane, "#{window_id}"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            session = Proc.run(tmux, ["display-message", "-p", "#{session_name}"]).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (session, pane, window, socket, tmux)
    }

    /// Short unified diff (drop the 2 header lines, cap at 16 changed lines) —
    /// ports `cn_diff`, shelling to the always-present `/usr/bin/diff`.
    static func diffPreview(old: String, new: String) -> String {
        let dir = FileManager.default.temporaryDirectory
        let oldF = dir.appendingPathComponent("cn-old-\(UUID().uuidString)")
        let newF = dir.appendingPathComponent("cn-new-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: oldF); try? FileManager.default.removeItem(at: newF) }
        do {
            try Data(old.utf8).write(to: oldF)
            try Data(new.utf8).write(to: newF)
        } catch { return "" }
        var out = Proc.run("/usr/bin/diff", ["-u", oldF.path, newF.path]).out
        if out.hasSuffix("\n") { out.removeLast() }
        guard !out.isEmpty else { return "" }
        let lines = out.components(separatedBy: "\n").dropFirst(2).prefix(16)
        return lines.joined(separator: "\n")
    }

    /// Assemble the `NotifyRequest` the server already decodes — the in-process
    /// port of `cn_build_payload`. Empty fields become nil so the encoder omits
    /// them (matching jq's null-stripping).
    static func buildPayload(input: HookInput, id: String, kind: NotifyKind,
                             title: String, context: String,
                             actions: [String]? = nil, diff: String = "") -> NotifyRequest {
        func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
        let cwd = input.cwd
        let term = terminalInfo()
        let tmux = tmuxInfo()
        return NotifyRequest(
            id: id, kind: kind,
            repoName: opt(repoName(cwd: cwd)),
            branch: opt(branch(cwd: cwd)),
            cwd: opt(cwd),
            sessionId: opt(input.sessionId),
            title: title,
            context: opt(context),
            toolName: opt(input.toolName),
            actions: actions,
            terminalPid: Int(term.pid),
            terminalApp: opt(term.app),
            windowTitle: opt(term.title),
            tty: opt(term.tty),
            itermSessionId: opt(itermSessionId()),
            tmuxSession: opt(tmux.session),
            tmuxPane: opt(tmux.pane),
            tmuxWindowId: opt(tmux.window),
            tmuxSocket: opt(tmux.socket),
            tmuxBin: opt(tmux.bin),
            diffPreview: opt(diff))
    }
}
