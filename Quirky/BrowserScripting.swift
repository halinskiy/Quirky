// Shared plumbing for the DOM and SVG extractors: browser detection, the
// one-time "allow JavaScript from Apple Events" switch, and a single serial
// queue that runs AppleScript one script at a time with a bounded wait on
// the browser. Both extractors ship only in the direct-distribution build
// (see their headers), so this compiles as empty in the MAS build.
#if !MAS_BUILD
import Cocoa

enum BrowserScripting {

    enum Browser {
        case safari
        case chromium(name: String)
    }

    /// Everything the background work needs to address a browser, resolved
    /// on the main thread so the script queue never touches
    /// `NSRunningApplication`.
    struct Target {
        let browser: Browser
        let bundleID: String
        let pid: pid_t
    }

    /// Why a script produced nothing. Every error used to collapse into an
    /// empty result that the UI answered with "Open in Safari/Chrome" —
    /// including a refused Automation permission and a browser that simply
    /// didn't answer.
    enum Failure: Error, Equatable {
        case noBrowser                 // the app in front isn't a supported browser
        case automationDenied          // -1743: Automation permission refused
        case javaScriptDisabled        // the browser rejects JavaScript from Apple Events
        case timedOut                  // -1712: the browser didn't answer in time
        case accessibilityUnavailable  // DOM: no window frame from the Accessibility API
        case superseded                // a newer request replaced this one before it ran
        case scriptError(Int)

        var userMessage: String {
            switch self {
            case .noBrowser: return "Open in Safari/Chrome"
            case .automationDenied: return "Allow Quirky in System Settings → Automation"
            case .javaScriptDisabled: return "Enable JavaScript from Apple Events in the browser"
            case .timedOut: return "The browser didn't respond"
            case .accessibilityUnavailable: return "Couldn't read the browser window"
            case .superseded: return ""
            case .scriptError(let code): return "Browser script failed (\(code))"
            }
        }

        var isPermissionProblem: Bool {
            self == .automationDenied || self == .javaScriptDisabled
        }
    }

    /// Monotonic ticket counter for requests that supersede each other.
    /// Issued on the caller's thread, checked on the script queue.
    final class RequestSlot {
        private var latest = 0
        private let lock = NSLock()

        func issue() -> Int {
            lock.lock(); defer { lock.unlock() }
            latest += 1
            return latest
        }

        func isCurrent(_ ticket: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return ticket == latest
        }
    }

    /// One script at a time. NSAppleScript isn't documented as thread-safe,
    /// and every quick mode switch used to race two scripts against the
    /// same browser from the global concurrent queue.
    private static let queue = DispatchQueue(label: "com.threempq.quirky.applescript", qos: .userInitiated)

    private static let chromiumBundleIDs: Set<String> = [
        "com.google.chrome",
        "company.thebrowser.browser",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "ai.perplexity.comet",
    ]

    // MARK: - Target resolution (main thread)

    static func target(for app: NSRunningApplication?) -> Target? {
        guard let app, let bundleID = app.bundleIdentifier,
              let browser = detectBrowser(bundleID: bundleID, name: app.localizedName) else { return nil }
        return Target(browser: browser, bundleID: bundleID, pid: app.processIdentifier)
    }

    private static func detectBrowser(bundleID: String, name: String?) -> Browser? {
        let lower = bundleID.lowercased()
        if lower == "com.apple.safari" { return .safari }
        if chromiumBundleIDs.contains(lower) || lower.contains("chrome") || lower.contains("chromium") {
            return .chromium(name: name ?? "Google Chrome")
        }
        return nil
    }

    // MARK: - Running scripts

    /// Runs `js` in the target browser's front document and hands the
    /// script's string result to `completion` on the main thread. A request
    /// issued against a `slot` is skipped when a newer request on the same
    /// slot was issued before it got its turn on the queue.
    static func run(js: String, in target: Target, timeoutSeconds: Int, slot: RequestSlot? = nil,
                    completion: @escaping (Result<String, Failure>) -> Void) {
        let source = script(for: target.browser, js: js, timeoutSeconds: timeoutSeconds)
        let ticket = slot?.issue()
        queue.async {
            if let slot, let ticket, !slot.isCurrent(ticket) {
                DispatchQueue.main.async { completion(.failure(.superseded)) }
                return
            }
            BrowserScripting.ensureJavaScriptEnabled(for: target)
            let result = BrowserScripting.execute(source)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The script, wrapped in `with timeout` so a hung browser costs
    /// `timeoutSeconds`, not the Apple Event default of about two minutes —
    /// per request, on a queue that serves every request.
    private static func script(for browser: Browser, js: String, timeoutSeconds: Int) -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
        let body: String
        switch browser {
        case .safari:
            body = "tell application \"Safari\" to do JavaScript \"\(escaped)\" in document 1"
        case .chromium(let name):
            body = """
            tell application "\(name)"
                tell active tab of front window
                    execute javascript "\(escaped)"
                end tell
            end tell
            """
        }
        return """
        with timeout of \(timeoutSeconds) seconds
        \(body)
        end timeout
        """
    }

    private static func execute(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.scriptError(0)) }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (info[NSAppleScript.errorMessage] as? String) ?? ""
            NSLog("Quirky: AppleScript failed (\(code)): \(message)")
            return .failure(classify(code: code, message: message))
        }
        return .success(descriptor.stringValue ?? "")
    }

    private static func classify(code: Int, message: String) -> Failure {
        switch code {
        case -1743: return .automationDenied        // errAEEventNotPermitted
        case -1712: return .timedOut                // errAETimeout
        case -600, -1728: return .noBrowser         // procNotFound, errAENoSuchObject (no document / window)
        default:
            // Safari and the Chromium browsers word the refusal differently,
            // but both name the feature.
            if message.range(of: "javascript", options: .caseInsensitive) != nil { return .javaScriptDisabled }
            return .scriptError(code)
        }
    }

    /// Flips the browser's "Allow JavaScript from Apple Events" preference
    /// the first time, via `defaults`. Runs on the script queue: a Process
    /// launch plus `waitUntilExit` used to run on the main thread.
    private static func ensureJavaScriptEnabled(for target: Target) {
        let domain: String
        let key: String
        switch target.browser {
        case .safari:
            domain = "com.apple.Safari"
            key = "AllowJavaScriptFromAppleEvents"
        case .chromium:
            domain = target.bundleID
            key = "AppleScriptEnabled"
        }
        if UserDefaults(suiteName: domain)?.bool(forKey: key) == true { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", domain, key, "-bool", "true"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // `waitUntilExit` on a process that never launched is undefined;
            // the old `try?` fell straight into it.
            NSLog("Quirky: could not enable JavaScript from Apple Events for \(domain): \(error)")
        }
    }
}
#endif
