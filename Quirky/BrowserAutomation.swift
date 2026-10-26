#if !MAS_BUILD
import Cocoa
import OSLog

/// DOM and SVG share browser detection and structured errors. No preference writes:
/// enabling JavaScript from Apple Events is an explicit choice in the browser.
struct BrowserAutomationFailure: Error {
    enum Kind: String {
        case unsupportedBrowser, javaScriptDisabled, automationDenied, noWindow
        case scriptFailed, invalidResponse, contentFrameUnavailable
    }
    let kind: Kind
    var appleScriptCode: Int? = nil

    init(kind: Kind, appleScriptCode: Int? = nil) {
        self.kind = kind
        self.appleScriptCode = appleScriptCode
    }

    init(appleScriptError error: NSDictionary) {
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        // Inspect locally only. The dictionary/message can contain page content.
        let message = (error[NSAppleScript.errorMessage] as? String ?? "").lowercased()
        let kind: Kind
        if code == -1743 || code == -10004 { kind = .automationDenied }
        else if message.contains("javascript") && (message.contains("turned off") || message.contains("disabled") || message.contains("not allowed")) {
            kind = .javaScriptDisabled
        } else if code == -1728 { kind = .noWindow }
        else { kind = .scriptFailed }
        self.init(kind: kind, appleScriptCode: code)
    }

    var userMessage: String {
        switch kind {
        case .unsupportedBrowser: return "Откройте страницу в поддерживаемом браузере (Nothing, Chrome, Safari…)"
        case .javaScriptDisabled: return "Включите в браузере View > Developer > Allow JavaScript from Apple Events"
        case .automationDenied: return "Разрешите Quirky управлять браузером: System Settings > Privacy & Security > Automation"
        case .noWindow: return "Откройте окно браузера с активной вкладкой"
        case .contentFrameUnavailable: return "Не удалось определить область страницы браузера"
        case .invalidResponse: return "Браузер вернул некорректный результат. Попробуйте другую вкладку"
        case .scriptFailed:
            return "Не удалось выполнить AppleScript в браузере" + (appleScriptCode.map { " (код \($0))" } ?? "")
        }
    }
}

enum BrowserAutomation {
    enum Browser {
        case safari
        case chromium(bundleID: String)
    }
    enum Operation: String {
        case domScan = "dom_scan", svgScan = "svg_scan", svgExtract = "svg_extract"
        var mode: String { self == .domScan ? "dom" : "svg" }
    }

    static func detectBrowser(bundleID: String?) -> Browser? {
        guard let bundleID else { return nil }
        let lower = bundleID.lowercased()
        if lower == "com.apple.safari" { return .safari }
        let chromiumIDs = [
            "com.google.chrome", "company.thebrowser.browser", "com.brave.browser",
            "com.microsoft.edgemac", "com.vivaldi.vivaldi", "com.operasoftware.opera",
            "ai.perplexity.comet", "com.3mpq.nothing",
        ]
        if chromiumIDs.contains(lower) || lower.contains("chrome") || lower.contains("chromium") {
            return .chromium(bundleID: bundleID)
        }
        return nil
    }

    static func appleScript(browser: Browser, js: String) -> String {
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        switch browser {
        case .safari: return "tell application \"Safari\" to do JavaScript \"\(escaped(js))\" in document 1"
        case .chromium(let bundleID):
            return "tell application id \"\(escaped(bundleID))\" to tell active tab of front window to execute javascript \"\(escaped(js))\""
        }
    }

    /// Run only on appleScriptQueue, including the tests' sequential script calls.
    static func readArray<T>(_ source: String, decode: (Data) throws -> [T]) -> Result<[T], BrowserAutomationFailure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.init(kind: .scriptFailed)) }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error { return .failure(.init(appleScriptError: error)) }
        guard let json = descriptor.stringValue, let data = json.data(using: .utf8),
              let values = try? decode(data) else { return .failure(.init(kind: .invalidResponse)) }
        return .success(values)
    }

    static func diagnosticData<T>(operation: Operation, bundleID: String?, started: TimeInterval,
                                  result: Result<[T], BrowserAutomationFailure>) -> [String: Any] {
        var data: [String: Any] = ["mode": operation.mode, "operation": operation.rawValue,
            "browser_bundle_id": bundleID ?? "unknown",
            "duration_ms": max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))]
        switch result {
        case .success(let values):
            data["status"] = values.isEmpty ? "empty" : "success"
            data["result_count"] = values.count
        case .failure(let error):
            data["status"] = "error"
            data["result_count"] = 0
            data["error_kind"] = error.kind.rawValue
            if let code = error.appleScriptCode { data["applescript_error_code"] = code }
        }
        return data
    }

    static func complete<T>(_ result: Result<[T], BrowserAutomationFailure>, operation: Operation,
                            app: NSRunningApplication?, started: TimeInterval,
                            completion: @escaping (Result<[T], BrowserAutomationFailure>) -> Void) {
        BrowserDiagnostics.record(diagnosticData(operation: operation, bundleID: app?.bundleIdentifier, started: started, result: result))
        DispatchQueue.main.async { completion(result) }
    }
}

/// Direct builds only. Configured by Scripts/build.sh from the ingest key, never
/// the dashboard token. Missing config means local OSLog only; no identifiers or
/// network requests. Deliberately accepts only BrowserAutomation's typed outcome.
private enum BrowserDiagnostics {
    private static let log = Logger(subsystem: "com.threempq.quirky", category: "browser")
    private static let queue = DispatchQueue(label: "com.threempq.quirky.browser-diagnostics", qos: .utility)
    private static let sessionID = UUID().uuidString
    private static var sequence = 0
    private static let network = URLSession(configuration: .ephemeral)

    static func record(_ data: [String: Any]) {
        // This dictionary contains no page strings, selectors, URLs or script source.
        if let json = try? JSONSerialization.data(withJSONObject: data), let line = String(data: json, encoding: .utf8) {
            log.notice("browser operation \(line, privacy: .public)")
        }
        queue.async {
            guard let endpoint = Bundle.main.object(forInfoDictionaryKey: "TelemetryEndpoint") as? String,
                  let url = URL(string: endpoint), url.scheme == "https",
                  url.host == "apps-telemetry.empqwork.workers.dev", url.path == "/e",
                  let key = Bundle.main.object(forInfoDictionaryKey: "TelemetryKey") as? String, !key.isEmpty else { return }
            let defaults = UserDefaults.standard
            let installKey = "telemetry.install_id"
            let installID = defaults.string(forKey: installKey) ?? UUID().uuidString
            defaults.set(installID, forKey: installKey)
            sequence += 1
            let event: [String: Any] = ["app": "Quirky", "type": "browser_operation", "session_id": sessionID,
                "install_id": installID, "seq": sequence,
                "ver": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "ts": ISO8601DateFormatter().string(from: Date()), "data": data]
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-ik")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["events": [event]])
            network.dataTask(with: request) { _, response, error in
                if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
                    log.notice("Browser diagnostics delivery failed")
                }
            }.resume()
        }
    }
}
#endif
