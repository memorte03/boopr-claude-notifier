import Foundation
import SwiftUI
import Combine
import AppKit
import ApplicationServices

struct ProgressTimer: Equatable, Sendable {
    let start: Date
    let duration: TimeInterval
}

/// A notification that timed out unattended, demoted to a persistent pill in
/// the pill bar until the user jumps to it, dismisses it, visits the pane, or
/// the session produces a newer event.
struct PendingAction: Identifiable, Sendable {
    /// Session identity — one pill per Claude session.
    let key: String
    var req: NotifyRequest
    var since: Date
    var id: String { key }

    static func key(for req: NotifyRequest) -> String {
        if let sid = req.sessionId { return "sid:" + sid }
        // No session id: distinguish distinct panes in the same directory by
        // terminal pid so two sessions in one cwd don't collapse to one pill.
        if let cwd = req.cwd { return "cwd:\(cwd)#\(req.terminalPid.map(String.init) ?? "")" }
        return "id:" + req.id
    }
}

@MainActor
final class NotificationStore: ObservableObject {
    @Published private(set) var current: NotifyRequest?
    @Published private(set) var queue: [NotifyRequest] = []
    /// Drives the close-button countdown ring.
    @Published private(set) var currentTimer: ProgressTimer?

    let chime = ChimePlayer()

    /// Set when the HTTP server failed to start (port in use, etc.) so the
    /// menu can show a visible error instead of the app silently no-opping.
    @Published var serverError: String?

    /// Launch-at-login — single source of truth shared by the menu and Settings.
    @Published var launchAtLogin: Bool = LoginItem.isEnabled
    func toggleLaunchAtLogin() {
        _ = LoginItem.toggle()
        launchAtLogin = LoginItem.isEnabled
    }

    /// Cached TCC status for the menu, refreshed off the render path so opening
    /// the menu doesn't block on a synchronous Apple Event.
    @Published var axStatus: PermissionsStatus.State = .denied
    @Published var automationStatus: PermissionsStatus.State = .notDetermined
    func refreshPermissions() {
        axStatus = PermissionsStatus.accessibility()   // cheap, no IPC
        DispatchQueue.global(qos: .userInitiated).async {
            let auto = PermissionsStatus.automation(bundleID: "com.mitchellh.ghostty")
            DispatchQueue.main.async { self.automationStatus = auto }
        }
    }

    /// One binding factory for the notification-kind toggles, shared by the menu
    /// and the Settings checkboxes (no duplicated get/set logic).
    func bindingForKind(_ kind: NotifyKind) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.enabledKinds.contains(kind) ?? false },
            set: { [weak self] on in
                guard let self else { return }
                if on { self.enabledKinds.insert(kind) } else { self.enabledKinds.remove(kind) }
            }
        )
    }

    /// Missed notifications, newest first. Drives the pill bar.
    @Published private(set) var pending: [PendingAction] = [] {
        didSet {
            reevaluatePendingWatcher()
            onPendingChange?()
        }
    }

    /// AppDelegate hook for showing/hiding the pill bar window.
    var onPendingChange: (() -> Void)?

    /// Master switch for the pill bar (Settings → General).
    @Published var pillsEnabled: Bool = UserDefaults.standard.object(forKey: "pillsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pillsEnabled, forKey: "pillsEnabled")
            if !pillsEnabled { pending = [] }
        }
    }

    /// Kinds worth keeping around: done-needs-review, waiting-for-input, and
    /// timed-out permissions (Claude is sitting on its native prompt).
    private let pillKinds: Set<NotifyKind> = [.stop, .idle, .permission, .ask]

    /// Which kinds actually surface (chime + overlay). Anything else is dropped.
    /// Persisted; toggled from the menu bar.
    @Published var enabledKinds: Set<NotifyKind> = NotificationStore.loadEnabledKinds() {
        didSet {
            UserDefaults.standard.set(enabledKinds.map(\.rawValue).sorted(), forKey: "enabledKinds")
        }
    }

    private static func loadEnabledKinds() -> Set<NotifyKind> {
        guard let raw = UserDefaults.standard.stringArray(forKey: "enabledKinds") else {
            return [.stop, .permission, .ask, .error]
        }
        return Set(raw.compactMap(NotifyKind.init(rawValue:)))
    }

    /// In-memory "always allow X in this Claude session" allowlist. Cleared on
    /// app restart (not persisted — by design; it's session-scoped).
    /// Keyed by Claude Code's session_id, value is the set of tool names.
    private var sessionAllows: [String: Set<String>] = [:]

    func alwaysAllow(req: NotifyRequest) {
        guard let sid = req.sessionId, let tool = req.toolName else { return }
        sessionAllows[sid, default: []].insert(tool)
    }

    /// id → continuation waiting for a PermissionResponse
    private var pendingDecisions: [String: CheckedContinuation<PermissionResponse, Never>] = [:]
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var dismissTasks: [String: Task<Void, Never>] = [:]

    /// Timeout for a permission prompt before we auto-respond "ask" (defer to
    /// native prompt). Persisted ("permissionTimeout", seconds). Keep it under
    /// the hooks' 15s curl --max-time so the server answers before curl gives up.
    @Published var permissionTimeout: TimeInterval = {
        let v = UserDefaults.standard.double(forKey: "permissionTimeout")
        return v > 0 ? min(v, 14) : 10
    }() {
        didSet {
            let clamped = min(max(permissionTimeout, 1), 14)
            if clamped != permissionTimeout { permissionTimeout = clamped; return }
            UserDefaults.standard.set(permissionTimeout, forKey: "permissionTimeout")
        }
    }

    /// How long non-permission overlays stay up before auto-dismissing.
    @Published var dismissDuration: TimeInterval = {
        let v = UserDefaults.standard.double(forKey: "dismissDuration")
        return v > 0 ? v : 10
    }() {
        didSet { UserDefaults.standard.set(dismissDuration, forKey: "dismissDuration") }
    }

    var onChange: (() -> Void)?

    /// Auto-dismiss duration for any kind.
    private func autoDuration(for kind: NotifyKind) -> TimeInterval? {
        switch kind {
        case .permission: return permissionTimeout
        default:          return dismissDuration
        }
    }

    func enqueue(_ req: NotifyRequest) {
        // Drop kinds the user has disabled entirely (no chime, no overlay) —
        // and crucially do NOT touch the session's pill: a suppressed event
        // isn't a "newer notification". (This was the silent-vanish bug: an idle
        // Notification, which the user has disabled, used to eat the pill on its
        // way to being dropped.)
        guard enabledKinds.contains(req.kind) else { return }
        // Past here the event surfaces (or the user is right at the session), so
        // it supersedes the pill: the live overlay replaces it, re-demoting with
        // newer content on timeout if still unattended.
        pending.removeAll { $0.key == PendingAction.key(for: req) }
        // Always chime — a frontmost terminal window doesn't prove the user is
        // at the machine (they may have stepped away), so the audio cue still
        // matters. Only the visual overlay is suppressed when they're
        // demonstrably at the session.
        chime.play(for: req.kind)
        if isTerminalFocused(req: req) { return }
        if current == nil {
            current = req
            scheduleTimers(for: req)
        } else {
            queue.append(req)
        }
        onChange?()
    }

    /// Returns true only when we're confident the user is looking at THIS
    /// specific Claude session — not just any window of the same terminal app.
    ///
    /// Two-stage check:
    ///   1. App-level: frontmost app matches the captured PID *or* bundle ID
    ///      (bundle-ID fallback covers tmux/screen, where the shell isn't a
    ///      descendant of the terminal so terminalPid can be empty).
    ///   2. Window-level: the frontmost window's AX title contains the session's
    ///      cwd basename or repo name. Most terminals show the cwd in the
    ///      window title; this lets us disambiguate multiple windows of one app.
    ///
    /// If we can't read the window title (no AX permission, no focused window),
    /// we conservatively report NOT focused → the overlay is shown. Better to
    /// alert too much than miss.
    private func isTerminalFocused(req: NotifyRequest) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let pidMatch    = req.terminalPid.map { front.processIdentifier == pid_t($0) } ?? false
        let bundleMatch = req.terminalApp.map { front.bundleIdentifier == $0 } ?? false
        guard pidMatch || bundleMatch else { return false }

        // tmux path: deterministic. The pane must be active in its session and
        // the client showing that session must hold OS focus (tmux tracks
        // FocusIn/FocusOut per client) — title heuristics can't tell two
        // same-app windows apart, this can.
        if let focused = TmuxMultiplexer.shared.isPaneFocused(req: req) { return focused }

        return isSessionWindowFocused(req: req, pid: front.processIdentifier)
    }

    private func isSessionWindowFocused(req: NotifyRequest, pid: pid_t) -> Bool {
        guard let title = focusedWindowTitle(pid: pid), !title.isEmpty else {
            return false
        }
        // tmux session name (best for multi-window tmux setups; requires
        // `set -g set-titles on; set -g set-titles-string "#S"` in ~/.tmux.conf
        // so the terminal title surfaces the session name).
        if let s = req.tmuxSession, !s.isEmpty, title.contains(s) { return true }
        // cwd basename (works without tmux config when terminal title shows cwd).
        if let cwd = req.cwd {
            let base = (cwd as NSString).lastPathComponent
            if base.count >= 3, title.contains(base) { return true }
        }
        // Repo name (covers cwd that's a sub-path of the repo).
        if let repo = req.repoName, repo.count >= 3, title.contains(repo) {
            return true
        }
        return false
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = winRef as! AXUIElement   // type verified above
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success
        else { return nil }
        return titleRef as? String
    }

    private func scheduleTimers(for req: NotifyRequest) {
        guard let dur = autoDuration(for: req.kind) else {
            currentTimer = nil
            return
        }
        currentTimer = ProgressTimer(start: Date(), duration: dur)

        // Permission timeout is owned by enqueuePermission (it has to resume
        // the continuation). Non-permission auto-dismiss is owned here.
        if req.kind != .permission {
            let id = req.id
            dismissTasks[id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(dur * 1_000_000_000))
                if !Task.isCancelled, self.current?.id == id {
                    self.dismiss(id: id, reason: .timeout)
                }
            }
        }
    }

    enum DismissReason {
        case user      // explicit ✕ — seen, not wanted
        case timeout   // unattended — demote to a pill
        case handled   // jumped / approved / denied
    }

    struct DecisionHandle: Sendable {
        fileprivate let task: Task<PermissionResponse, Never>
        /// Awaits the user's decision (or the timeout fallback).
        func awaitDecision() async -> PermissionResponse { await task.value }
    }

    func enqueuePermission(_ req: NotifyRequest) -> DecisionHandle {
        var req = req
        if req.actions == nil || req.actions?.isEmpty == true {
            req.actions = ["Approve", "Deny"]
        }
        let key = PendingAction.key(for: req)

        // If permission notifications are disabled, defer to native instantly —
        // and leave the pill alone (a suppressed event isn't a new pill).
        guard enabledKinds.contains(.permission) else {
            return DecisionHandle(task: Task {
                PermissionResponse(decision: "ask", reason: "disabled")
            })
        }

        // Session-allow short-circuit: tool already approved by "Always" earlier
        // in this Claude session. Auto-approve without surfacing — and leave the
        // pill (the user didn't act on it).
        if let sid = req.sessionId, let tool = req.toolName,
           sessionAllows[sid]?.contains(tool) == true {
            return DecisionHandle(task: Task {
                PermissionResponse(decision: "allow", reason: "always-allow session-scoped")
            })
        }

        // If the terminal session is already frontmost, the user sees Claude's
        // native prompt — defer to it instantly, and clear the pill since they're
        // right there. Still chime (they may have stepped away from a frontmost
        // terminal); only the overlay is suppressed.
        if isTerminalFocused(req: req) {
            chime.play(for: req.kind)
            pending.removeAll { $0.key == key }
            return DecisionHandle(task: Task {
                PermissionResponse(decision: "ask", reason: "session focused")
            })
        }
        // A surfacing permission supersedes the pill (enqueue does the removal
        // when the overlay opens, below).

        let id = req.id
        let task = Task<PermissionResponse, Never> {
            await withCheckedContinuation { (cont: CheckedContinuation<PermissionResponse, Never>) in
                Task { @MainActor in
                    // Guard against a duplicate in-flight id (client-supplied):
                    // resolve the existing waiter "ask" rather than orphan it.
                    if let existing = self.pendingDecisions.removeValue(forKey: id) {
                        self.timeoutTasks.removeValue(forKey: id)?.cancel()
                        existing.resume(returning: PermissionResponse(decision: "ask", reason: "superseded by duplicate id"))
                    }
                    self.pendingDecisions[id] = cont
                    self.enqueue(req)
                    let timeout = self.permissionTimeout
                    self.timeoutTasks[id] = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        if !Task.isCancelled { self.timeoutDecision(id: id) }
                    }
                }
            }
        }
        return DecisionHandle(task: task)
    }

    private func timeoutDecision(id: String) {
        guard let cont = pendingDecisions.removeValue(forKey: id) else { return }
        timeoutTasks.removeValue(forKey: id)
        cont.resume(returning: PermissionResponse(decision: "ask", reason: "timeout"))
        // The hook fell back to Claude's native prompt — the session is still
        // waiting on the user, so keep it visible as a pill.
        if let req = findRequest(id: id) { demoteToPending(req) }
        // Remove the answered request from the visible state. If it was merely
        // queued (a later prompt is showing), drop it from the queue so it never
        // resurfaces as a stale overlay that would keystroke the terminal.
        if current?.id == id { advance() }
        else { queue.removeAll { $0.id == id }; onChange?() }
    }

    func resolve(id: String, decision: String, reason: String? = nil) {
        if let cont = pendingDecisions.removeValue(forKey: id) {
            // Blocking flow: a /permission curl is waiting on us.
            cont.resume(returning: PermissionResponse(decision: decision, reason: reason))
        } else if let req = findRequest(id: id), req.kind == .permission {
            // Fire-and-forget flow (default): forward the choice into the
            // terminal's native 1/2 prompt.
            let digit = decision == "allow" ? "1" : "2"
            TerminalKeystroke.sendDigit(digit, to: req)
        }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        dismissTasks.removeValue(forKey: id)?.cancel()
        if current?.id == id { advance() }
    }

    private func findRequest(id: String) -> NotifyRequest? {
        if current?.id == id { return current }
        return queue.first { $0.id == id }
    }

    /// User jumped into the session to handle it natively. Unblock any waiting
    /// /permission hook with "ask" (Claude re-shows its own 1/2 prompt in the
    /// terminal we just raised) — without synthesizing a keystroke — then clear
    /// the overlay. For non-permission kinds there's no continuation, so this
    /// degrades to a plain dismiss.
    func jumpResolve(id: String) {
        // Raising the target terminal fires an app-activation that the pending
        // watcher would otherwise act on — suppress it so jumping one session
        // doesn't sweep away unrelated sessions' pills.
        suppressFocusSweep()
        if let cont = pendingDecisions.removeValue(forKey: id) {
            cont.resume(returning: PermissionResponse(decision: "ask", reason: "jumped to session"))
        }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        dismissTasks.removeValue(forKey: id)?.cancel()
        if current?.id == id { advance() } else { queue.removeAll { $0.id == id } }
        onChange?()
    }

    /// Dismiss a non-permission notification. Timeout dismissals demote the
    /// request to a pill; explicit/handled dismissals drop it for good.
    func dismiss(id: String, reason: DismissReason = .user) {
        dismissTasks.removeValue(forKey: id)?.cancel()
        if reason == .timeout, let req = findRequest(id: id) {
            demoteToPending(req)
        }
        if current?.id == id { advance() }
        else { queue.removeAll { $0.id == id } }
        onChange?()
    }

    // MARK: - pending pills

    private func demoteToPending(_ req: NotifyRequest) {
        guard pillsEnabled, pillKinds.contains(req.kind) else { return }
        // Already looking at the session — nothing is actually missed.
        if isTerminalFocused(req: req) { return }
        let key = PendingAction.key(for: req)
        pending.removeAll { $0.key == key }
        pending.insert(PendingAction(key: key, req: req, since: Date()), at: 0)
    }

    /// ✕ on a pill.
    func clearPending(key: String) {
        pending.removeAll { $0.key == key }
    }

    /// Click on a pill: jump to the session's terminal and clear it.
    func jumpPending(key: String) {
        guard let action = pending.first(where: { $0.key == key }) else { return }
        // Suppress the activation sweep the focus triggers, so jumping this pill
        // can't also clear other sessions' pills.
        suppressFocusSweep()
        SessionFocuser.focus(req: action.req)
        pending.removeAll { $0.key == key }
    }

    /// The user submitted a prompt in this session (UserPromptSubmit hook) —
    /// they're clearly looking at it, so drop its pill. Deterministic fallback
    /// for when the tmux focus watcher can't tell. Scoped to this session's key.
    func markSessionActive(_ req: NotifyRequest) {
        pending.removeAll { $0.key == PendingAction.key(for: req) }
    }

    // MARK: - pending focus watcher
    //
    // tmux has no push events, so auto-clearing pills when the user visits the
    // pane is a poll — scoped tightly: it only runs while pills exist AND the
    // frontmost app is one of their terminals, triggered by app activation.

    private var watchTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Briefly muffles the focus sweep after a programmatic jump: focusing the
    /// target terminal raises an app-activation that would otherwise make the
    /// watcher re-evaluate — and possibly clear — every other pill of that app.
    private var focusSweepSuppressedUntil = Date.distantPast
    private func suppressFocusSweep() {
        focusSweepSuppressedUntil = Date().addingTimeInterval(1.5)
    }

    func startPendingWatcher() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkPendingFocus()
                self?.reevaluatePendingWatcher()
            }
        }
    }

    private func reevaluatePendingWatcher() {
        let front = NSWorkspace.shared.frontmostApplication
        let shouldRun = !pending.isEmpty && pending.contains { matchesFrontApp($0.req, front) }
        if shouldRun, watchTimer == nil {
            // Explicit RunLoop.main (.common keeps it firing during menu tracking)
            // — this method is @MainActor, but don't rely on scheduledTimer's
            // implicit "current run loop" affinity.
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPendingFocus() }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchTimer = timer
        } else if !shouldRun {
            watchTimer?.invalidate()
            watchTimer = nil
        }
    }

    private func matchesFrontApp(_ req: NotifyRequest, _ front: NSRunningApplication?) -> Bool {
        guard let front else { return false }
        let pidMatch = req.terminalPid.map { front.processIdentifier == pid_t($0) } ?? false
        let bundleMatch = req.terminalApp.map { front.bundleIdentifier == $0 } ?? false
        return pidMatch || bundleMatch
    }

    private func checkPendingFocus() {
        // Conservative by design: a pill is auto-cleared ONLY on a *confirmed*
        // tmux pane focus. We deliberately do NOT remove on:
        //   - isPaneFocused == nil  (transient tmux failure OR pane gone) — a
        //     hiccup must never silently delete a pill the user didn't touch.
        //   - title-substring heuristics — they collide across same-named
        //     projects and clear unrelated sessions.
        // Non-tmux pills and gone panes rely on explicit signals instead: ✕,
        // pill-click, a newer session event, or UserPromptSubmit (/active).
        guard !pending.isEmpty, Date() >= focusSweepSuppressedUntil else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let candidates = pending.filter {
            matchesFrontApp($0.req, front) && TmuxMultiplexer.shared.handles($0.req)
        }
        guard !candidates.isEmpty else { return }

        // tmux checks shell out — keep them off the main thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let visited = candidates
                .filter { TmuxMultiplexer.shared.isPaneFocused(req: $0.req) == true }
                .map(\.key)
            guard !visited.isEmpty else { return }
            let toRemove = Set(visited)
            Task { @MainActor [weak self] in
                self?.pending.removeAll { toRemove.contains($0.key) }
            }
        }
    }

    private func advance() {
        if queue.isEmpty {
            current = nil
            currentTimer = nil
        } else {
            let next = queue.removeFirst()
            current = next
            scheduleTimers(for: next)
        }
        onChange?()
    }
}
