import Cocoa
import ApplicationServices

final class DOMExtractor {

    struct Element {
        let rect: CGRect    // CG coords (screen, top-left origin, logical points)
        let label: String   // tag.class.class — DevTools-style selector
    }

    // MARK: - Public

    static func getDOMElements(from app: NSRunningApplication?, completion: @escaping ([Element]) -> Void) {
        guard let app = app, let browser = detectBrowser(app) else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        // JS returns viewport-local CSS-pixel rects. The screen translation happens
        // in Swift via Accessibility — far more robust than computing chrome offsets
        // from window.screenY/outerHeight, which break under DevTools responsive
        // mode, page zoom != 100%, browsers with side chrome (Arc), etc.
        let js = """
        (function(){
        var R=[],MAX=2000;
        function sel(el){
        var t=(el.tagName||'').toLowerCase();if(!t)return '';
        var s=t;
        var id=el.id;
        if(id&&typeof id==='string'){var fid=id.trim().split(/\\s+/)[0];if(fid)s+='#'+fid;}
        var cn=el.className;
        if(cn&&cn.baseVal!==undefined)cn=cn.baseVal;
        if(typeof cn==='string'){
        var cls=cn.trim().split(/\\s+/).filter(Boolean).slice(0,8);
        if(cls.length)s+='.'+cls.join('.');}
        return s;}
        var all=document.body?document.body.getElementsByTagName('*'):[];
        for(var i=0;i<all.length&&R.length<MAX;i++){
        var el=all[i];
        var t=el.tagName;if(!t)continue;
        var tu=t.toUpperCase();
        if(tu==='SCRIPT'||tu==='STYLE'||tu==='META'||tu==='LINK'||tu==='HEAD')continue;
        var r=el.getBoundingClientRect();
        if(r.width<6||r.height<6)continue;
        if(r.bottom<0||r.top>window.innerHeight||r.right<0||r.left>window.innerWidth)continue;
        var cs=getComputedStyle(el);
        if(cs.display==='none'||cs.visibility==='hidden'||parseFloat(cs.opacity)===0)continue;
        var s=sel(el);if(!s)continue;
        R.push([r.left,r.top,r.width,r.height,s]);}
        return JSON.stringify(R);})()
        """

        let source = appleScript(browser: browser, js: js)
        let contentFrame = browserContentFrame(of: app)

        DispatchQueue.global(qos: .userInitiated).async {
            let viewportRects = runViewportRects(source)
            let elements: [Element]
            if let cf = contentFrame {
                elements = viewportRects.map { vr in
                    Element(
                        rect: CGRect(
                            x: cf.origin.x + vr.x,
                            y: cf.origin.y + vr.y,
                            width: vr.width,
                            height: vr.height
                        ),
                        label: vr.label
                    )
                }
            } else {
                elements = []
            }
            DispatchQueue.main.async { completion(elements) }
        }
    }

    // MARK: - Accessibility: browser content area frame

    /// Returns the content-area frame (where the page renders) in CG screen coords —
    /// top-left origin, logical points. Walks the AX hierarchy for AXWebArea (Safari)
    /// or AXScrollArea (Chromium). Falls back to the focused window frame.
    private static func browserContentFrame(of app: NSRunningApplication) -> CGRect? {
        let appAX = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let window = f as! AXUIElement

        if let webArea = findContentArea(in: window, depth: 0), let frame = axFrame(of: webArea) {
            return frame
        }
        return axFrame(of: window)
    }

    private static func findContentArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 10 { return nil }
        var roleVal: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        if let role = roleVal as? String, role == "AXWebArea" || role == "AXScrollArea" {
            return element
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let arr = children as? [AXUIElement] {
            for child in arr {
                if let found = findContentArea(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    // MARK: - Browser detection (mirrors SVGExtractor — independent on purpose)

    private enum Browser {
        case safari
        case chromium(name: String)
    }

    private static func detectBrowser(_ app: NSRunningApplication?) -> Browser? {
        guard let bid = app?.bundleIdentifier else { return nil }
        let lower = bid.lowercased()
        if lower == "com.apple.safari" {
            ensureSafariJSEnabled()
            return .safari
        }
        let chromiumIDs = [
            "com.google.chrome",
            "company.thebrowser.browser",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "com.vivaldi.vivaldi",
            "com.operasoftware.opera",
            "ai.perplexity.comet",
        ]
        for cid in chromiumIDs where lower == cid {
            ensureJSEnabled(bundleID: bid)
            return .chromium(name: app?.localizedName ?? "Google Chrome")
        }
        if lower.contains("chrome") || lower.contains("chromium") {
            ensureJSEnabled(bundleID: bid)
            return .chromium(name: app?.localizedName ?? "Google Chrome")
        }
        return nil
    }

    private static func ensureJSEnabled(bundleID: String) {
        let key = "AppleScriptEnabled"
        if UserDefaults(suiteName: bundleID)?.bool(forKey: key) == true { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", bundleID, key, "-bool", "true"]
        try? task.run()
        task.waitUntilExit()
    }

    private static func ensureSafariJSEnabled() {
        let key = "AllowJavaScriptFromAppleEvents"
        if UserDefaults(suiteName: "com.apple.Safari")?.bool(forKey: key) == true { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.Safari", key, "-bool", "true"]
        try? task.run()
        task.waitUntilExit()
    }

    private static func appleScript(browser: Browser, js: String) -> String {
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
        switch browser {
        case .safari:
            return "tell application \"Safari\" to do JavaScript \"\(escaped)\" in document 1"
        case .chromium(let name):
            return """
            tell application "\(name)"
                tell active tab of front window
                    execute javascript "\(escaped)"
                end tell
            end tell
            """
        }
    }

    private struct ViewportRect {
        let x, y, width, height: CGFloat
        let label: String
    }

    private static func runViewportRects(_ source: String) -> [ViewportRect] {
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return [] }
        guard let json = result.stringValue,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        return arr.compactMap { item in
            guard item.count == 5,
                  let x = (item[0] as? Double) ?? (item[0] as? Int).map(Double.init),
                  let y = (item[1] as? Double) ?? (item[1] as? Int).map(Double.init),
                  let w = (item[2] as? Double) ?? (item[2] as? Int).map(Double.init),
                  let h = (item[3] as? Double) ?? (item[3] as? Int).map(Double.init),
                  let label = item[4] as? String else { return nil }
            return ViewportRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h), label: label)
        }
    }
}
