import Cocoa

@main
struct BrowserAutomationTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { fatalError(message) }
        }
        check(BrowserAutomation.detectBrowser(bundleID: "com.3mpq.nothing") != nil, "Nothing supported")
        check(BrowserAutomation.detectBrowser(bundleID: "ai.perplexity.comet") != nil, "Comet supported")
        check(BrowserAutomation.detectBrowser(bundleID: "com.apple.Safari") != nil, "Safari supported")
        check(BrowserAutomation.detectBrowser(bundleID: "org.chromium.Chromium") != nil, "Chromium fallback")
        check(BrowserAutomation.detectBrowser(bundleID: "com.apple.finder") == nil, "unsupported app")

        func read(_ script: String) -> Result<[String], BrowserAutomationFailure> {
            BrowserAutomation.readArray(script) { try JSONDecoder().decode([String].self, from: $0) }
        }
        func failure(_ result: Result<[String], BrowserAutomationFailure>) -> BrowserAutomationFailure {
            if case .failure(let error) = result { return error }
            fatalError("Expected failure")
        }
        let disabled = failure(read("error \"Executing JavaScript through AppleScript is turned off.\" number 12"))
        check(disabled.kind == .javaScriptDisabled && disabled.appleScriptCode == 12, "Chromium disabled error")
        check(disabled.userMessage == "Включите в браузере View > Developer > Allow JavaScript from Apple Events", "actionable JS toast")
        check(disabled.userMessage(forBrowserBundleID: "com.apple.Safari").contains("Safari"), "Safari-specific JS guidance")
        check(disabled.userMessage(forBrowserBundleID: "com.3mpq.nothing") == disabled.userMessage, "Chromium guidance preserved")
        let denied = failure(read("error \"Not authorized to send Apple events\" number -1743"))
        check(denied.kind == .automationDenied && denied.userMessage.contains("Automation"), "Automation permission toast")
        check(failure(read("error \"window missing\" number -1728")).kind == .noWindow, "missing tab/window")
        check(failure(read("error \"sensitive page content\" number -9876")).kind == .scriptFailed, "generic error")
        check(failure(read("return \"not JSON\"")).kind == .invalidResponse, "malformed JSON")
        check(failure(read("return \"{}\"")).kind == .invalidResponse, "wrong JSON shape")
        if case .success(let empty) = read("return \"[]\"") { check(empty.isEmpty, "valid empty result") }
        else { fatalError("Empty array is not an error") }
        if case .success(let strings) = read("return \"[\\\"svg\\\"]\"") { check(strings == ["svg"], "valid JSON result") }
        else { fatalError("Valid array rejected") }
        let safe = BrowserAutomation.diagnosticData(operation: .domScan, bundleID: "com.3mpq.nothing", started: ProcessInfo.processInfo.systemUptime - 0.1, result: .failure(disabled) as Result<[String], BrowserAutomationFailure>)
        check(Set(safe.keys) == Set(["mode", "operation", "browser_bundle_id", "status", "duration_ms", "result_count", "error_kind", "applescript_error_code"]), "only diagnostic fields")
        check(safe["applescript_error_code"] as? Int == 12, "numeric error code")
        check((safe["duration_ms"] as? Int ?? 0) >= 99, "monotonic duration")
        let content = "private-title https://private.example/ clipboard OCR-text <svg>private</svg>"
        let successData = BrowserAutomation.diagnosticData(operation: .svgExtract, bundleID: "com.3mpq.nothing", started: ProcessInfo.processInfo.systemUptime, result: .success([content]) as Result<[String], BrowserAutomationFailure>)
        check(successData["status"] as? String == "success" && successData["result_count"] as? Int == 1, "success count")
        check(!String(describing: successData).contains("private"), "no extracted content")
        let generic = failure(read("error \"sensitive page content\" number -9876"))
        let errorData = BrowserAutomation.diagnosticData(operation: .svgScan, bundleID: nil, started: ProcessInfo.processInfo.systemUptime, result: .failure(generic) as Result<[String], BrowserAutomationFailure>)
        check(!String(describing: errorData).contains("sensitive"), "no raw AppleScript error text")
        let emptyData = BrowserAutomation.diagnosticData(operation: .domScan, bundleID: nil, started: ProcessInfo.processInfo.systemUptime, result: .success([]) as Result<[String], BrowserAutomationFailure>)
        check(emptyData["status"] as? String == "empty", "empty distinct from error")
        var callbacks = 0
        func rejected<T>(_ result: Result<[T], BrowserAutomationFailure>) {
            check(Thread.isMainThread, "UI completion on main thread")
            if case .failure(let error) = result { check(error.kind == .unsupportedBrowser, "typed unsupported browser") }
            else { fatalError("Unsupported browser must not become empty success") }
            callbacks += 1
        }
        DOMExtractor.getDOMElements(from: nil) { rejected($0) }
        SVGExtractor.getSVGBoundingBoxes(from: nil) { rejected($0) }
        SVGExtractor.extractSVGs(in: .zero, from: nil) { rejected($0) }
        let deadline = Date().addingTimeInterval(3)
        while callbacks < 3 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(callbacks == 3, "all extractor callbacks delivered")
        print("PASS: browser detection, AppleScript errors, JSON outcomes, content-free diagnostics, extractor completions")
    }
}
