import AppKit

/// Runs AppleScript off the main thread safely. `NSAppleScript` is main-thread
/// only, but the raisers run on a utility queue — so hop to main (guard against a
/// main-thread caller dead-locking on `main.sync`). Shared by the terminal
/// adapters (Ghostty, iTerm2, …).
enum AppleScript {
    /// Execute and return the script's string result (nil on error / no value).
    static func run(_ source: String) -> String? {
        func exec() -> String? {
            var error: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("AppleScript error: \(error)") }
            return out?.stringValue
        }
        if Thread.isMainThread { return exec() }
        var result: String?
        DispatchQueue.main.sync { result = exec() }
        return result
    }

    /// Execute for side effects; success = no error (don't rely on a string
    /// result, which a bare `activate` doesn't produce).
    @discardableResult
    static func runVoid(_ source: String) -> Bool {
        func exec() -> Bool {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("AppleScript error: \(error)"); return false }
            return true
        }
        if Thread.isMainThread { return exec() }
        var ok = false
        DispatchQueue.main.sync { ok = exec() }
        return ok
    }
}
