// DOM extraction uses AppleScript / Accessibility API on a foreign app
// (Safari, Chrome, Arc, …) to enumerate elements. Both routes are blocked
// by the App Store sandbox without entitlements Apple typically denies,
// so this file compiles as empty in the MAS build.
#if !MAS_BUILD
import Cocoa
import ApplicationServices

final class DOMExtractor {

    struct Element {
        let rect: CGRect    // CG coords (screen, top-left origin, logical points)
        let label: String   // tag.class.class — DevTools-style selector
    }

    /// Enumeration requests supersede each other: once the user has moved
    /// on to another mode, a queued request has nobody to answer to.
    private static let requestSlot = BrowserScripting.RequestSlot()
    /// Per-call cap on waiting for the browser's accessibility server. The
    /// system default is several seconds — per call — and the walk below
    /// makes many calls.
    private static let axTimeout: Float = 0.5
    /// Hard ceiling on the AX tree walk, so a huge or hung tree can't keep a
    /// thread busy indefinitely.
    private static let axNodeBudget = 400

    // MARK: - Public

    /// Elements of the page in the browser in front, in CG screen coords.
    /// `failure` says why `elements` is empty when it is. Completion runs on
    /// the main thread.
    static func getDOMElements(from app: NSRunningApplication?,
                               completion: @escaping ([Element], BrowserScripting.Failure?) -> Void) {
        guard let target = BrowserScripting.target(for: app) else {
            DispatchQueue.main.async { completion([], .noBrowser) }
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

        // The AX walk blocks for up to `axTimeout` per call when the browser
        // is busy. It used to run inline on the main thread, from the hotkey
        // path, with the overlay already covering the screen.
        DispatchQueue.global(qos: .userInitiated).async {
            let contentFrame = DOMExtractor.browserContentFrame(ofPID: target.pid)
            DispatchQueue.main.async {
                guard let cf = contentFrame else {
                    completion([], .accessibilityUnavailable)
                    return
                }
                BrowserScripting.run(js: js, in: target, timeoutSeconds: 3, slot: DOMExtractor.requestSlot) { result in
                    switch result {
                    case .failure(let failure):
                        completion([], failure)
                    case .success(let json):
                        let elements = DOMExtractor.parseViewportRects(json).map { vr in
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
                        completion(elements, nil)
                    }
                }
            }
        }
    }

    // MARK: - Accessibility: browser content area frame

    /// Returns the content-area frame (where the page renders) in CG screen coords —
    /// top-left origin, logical points. Walks the AX hierarchy for AXWebArea (Safari)
    /// or AXScrollArea (Chromium). Falls back to the focused window frame.
    /// Safe to call off the main thread; every call is bounded by `axTimeout`.
    private static func browserContentFrame(ofPID pid: pid_t) -> CGRect? {
        let appAX = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appAX, axTimeout)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let window = f as! AXUIElement

        var budget = axNodeBudget
        if let webArea = findContentArea(in: window, depth: 0, budget: &budget), let frame = axFrame(of: webArea) {
            return frame
        }
        return axFrame(of: window)
    }

    private static func findContentArea(in element: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
        if depth > 10 || budget <= 0 { return nil }
        budget -= 1
        AXUIElementSetMessagingTimeout(element, axTimeout)
        var roleVal: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        // A timeout means the browser isn't answering; every further call
        // would wait just as long, so give up on the whole walk.
        if roleStatus == .cannotComplete { budget = 0; return nil }
        if let role = roleVal as? String, role == "AXWebArea" || role == "AXScrollArea" {
            return element
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let arr = children as? [AXUIElement] {
            for child in arr {
                if let found = findContentArea(in: child, depth: depth + 1, budget: &budget) { return found }
                if budget <= 0 { return nil }
            }
        }
        return nil
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(element, axTimeout)
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

    // MARK: - Script result

    private struct ViewportRect {
        let x, y, width, height: CGFloat
        let label: String
    }

    private static func parseViewportRects(_ json: String) -> [ViewportRect] {
        guard let data = json.data(using: .utf8),
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
#endif
