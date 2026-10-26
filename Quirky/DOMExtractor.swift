// DOM extraction uses AppleScript / Accessibility API on a foreign app
// (Safari, Chrome, Arc, …) to enumerate elements. Both routes are blocked
// by the App Store sandbox without entitlements Apple typically denies,
// so this file compiles as empty in the MAS build.
#if !MAS_BUILD
import Cocoa
import ApplicationServices

/// NSAppleScript is not thread-safe. Every browser script (DOM and SVG) runs
/// on this one serial queue so a quick selection can't race a box scan.
let appleScriptQueue = DispatchQueue(label: "com.threempq.quirky.applescript", qos: .userInitiated)

final class DOMExtractor {

    struct Element {
        let rect: CGRect    // CG coords (screen, top-left origin, logical points)
        let label: String   // tag.class.class — DevTools-style selector
    }

    // MARK: - Public

    static func getDOMElements(from app: NSRunningApplication?, completion: @escaping (Result<[Element], BrowserAutomationFailure>) -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        func complete(_ result: Result<[Element], BrowserAutomationFailure>) {
            BrowserAutomation.complete(result, operation: .domScan, app: app, started: started, completion: completion)
        }
        guard let app, let browser = BrowserAutomation.detectBrowser(bundleID: app.bundleIdentifier) else {
            complete(.failure(.init(kind: .unsupportedBrowser)))
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

        let source = BrowserAutomation.appleScript(browser: browser, js: js)
        let contentFrame = browserContentFrame(of: app)

        appleScriptQueue.async {
            let result = runViewportRects(source).flatMap { viewportRects -> Result<[Element], BrowserAutomationFailure> in
                guard let cf = contentFrame else { return .failure(.init(kind: .contentFrameUnavailable)) }
                return .success(viewportRects.map { vr in
                    Element(rect: CGRect(x: cf.origin.x + vr.x, y: cf.origin.y + vr.y,
                                         width: vr.width, height: vr.height), label: vr.label)
                })
            }
            complete(result)
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

    private struct ViewportRect {
        let x, y, width, height: CGFloat
        let label: String
    }

    private static func runViewportRects(_ source: String) -> Result<[ViewportRect], BrowserAutomationFailure> {
        BrowserAutomation.readArray(source) { data in
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
                throw BrowserAutomationFailure(kind: .invalidResponse)
            }
            return try arr.map { item in
                guard item.count == 5,
                      let x = item[0] as? Double, let y = item[1] as? Double,
                      let w = item[2] as? Double, let h = item[3] as? Double,
                      [x, y, w, h].allSatisfy({ $0.isFinite }), w > 0, h > 0,
                      let label = item[4] as? String else { throw BrowserAutomationFailure(kind: .invalidResponse) }
                return ViewportRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h), label: label)
            }
        }
    }
}
#endif
