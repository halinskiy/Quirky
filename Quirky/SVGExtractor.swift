// SVG extraction depends on AppleScript to inject JS into Safari / Chrome /
// other browsers. App Store sandbox forbids cross-app AppleScript without
// temporary-exception entitlements Apple frequently rejects, so the MAS
// build compiles this file as empty. Direct-distribution build keeps
// full functionality.
#if !MAS_BUILD
import Cocoa

final class SVGExtractor {

    // MARK: - Public

    /// Returns bounding boxes of all visible SVGs on the page in CG coordinates (top-left origin).
    static func getSVGBoundingBoxes(from app: NSRunningApplication?, completion: @escaping (Result<[CGRect], BrowserAutomationFailure>) -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        func complete(_ result: Result<[CGRect], BrowserAutomationFailure>) {
            BrowserAutomation.complete(result, operation: .svgScan, app: app, started: started, completion: completion)
        }
        guard let browser = BrowserAutomation.detectBrowser(bundleID: app?.bundleIdentifier) else {
            complete(.failure(.init(kind: .unsupportedBrowser)))
            return
        }

        let js = """
        (function(){
        var z=window.outerWidth/window.innerWidth;
        var ch=window.outerHeight-window.innerHeight*z;
        var R=[];
        function svgRect(s){
        var r=s.getBoundingClientRect();
        try{var bb=s.getBBox();var ctm=s.getScreenCTM();
        if(bb.width>0&&bb.height>0&&ctm){
        var w=bb.width*Math.abs(ctm.a),h=bb.height*Math.abs(ctm.d);
        if(w>=4&&h>=4)return{left:r.left+(r.width-w)/2,top:r.top+(r.height-h)/2,width:w,height:h};
        }}catch(e){}
        return{left:r.left,top:r.top,width:r.width,height:r.height};}
        document.querySelectorAll('svg').forEach(function(s){
        var r=svgRect(s);
        if(r.width<4||r.height<4)return;
        var cs=getComputedStyle(s);
        if(cs.display==='none'||cs.visibility==='hidden')return;
        R.push([window.screenX+r.left*z,window.screenY+ch+r.top*z,r.width*z,r.height*z]);});
        document.querySelectorAll('img').forEach(function(img){
        var src=img.getAttribute('src')||'';
        if(!/\\.svg($|\\?)/i.test(src))return;
        var r=img.getBoundingClientRect();
        if(r.width<4||r.height<4)return;
        var cs=getComputedStyle(img);
        if(cs.display==='none'||cs.visibility==='hidden')return;
        R.push([window.screenX+r.left*z,window.screenY+ch+r.top*z,r.width*z,r.height*z]);});
        return JSON.stringify(R);})()
        """

        let source = BrowserAutomation.appleScript(browser: browser, js: js)

        appleScriptQueue.async {
            let boxes = runBoxes(source)
            complete(boxes)
        }
    }

    static func extractSVGs(in screenRect: CGRect, from app: NSRunningApplication?, completion: @escaping (Result<[String], BrowserAutomationFailure>) -> Void) {
        let started = ProcessInfo.processInfo.systemUptime
        func complete(_ result: Result<[String], BrowserAutomationFailure>) {
            BrowserAutomation.complete(result, operation: .svgExtract, app: app, started: started, completion: completion)
        }
        guard let browser = BrowserAutomation.detectBrowser(bundleID: app?.bundleIdentifier) else {
            complete(.failure(.init(kind: .unsupportedBrowser)))
            return
        }

        let js = buildJavaScript(for: screenRect)
        let source = BrowserAutomation.appleScript(browser: browser, js: js)

        appleScriptQueue.async {
            let svgs = run(source)
            complete(svgs)
        }
    }

    static func copyToClipboard(_ svgs: [String]) {
        guard !svgs.isEmpty else { return }
        let combined = svgs.count == 1 ? svgs[0] : combineSVGs(svgs)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(combined, forType: .string)
        if let data = combined.data(using: .utf8) {
            pb.setData(data, forType: NSPasteboard.PasteboardType("public.svg-image"))
        }
    }

    // MARK: - JavaScript

    private static func buildJavaScript(for r: CGRect) -> String {
        // screenRect is CG coordinates: top-left origin, points
        return """
        (function(){
        var sX=\(Int(r.origin.x)),sY=\(Int(r.origin.y)),sW=\(Int(r.width)),sH=\(Int(r.height));
        var z=window.outerWidth/window.innerWidth;
        var ch=window.outerHeight-window.innerHeight*z;
        var R=[],pad=15;
        function hit(x,y,w,h){return x<sX+sW+pad&&x+w>sX-pad&&y<sY+sH+pad&&y+h>sY-pad;}
        function resolve(svg){
        var c=svg.cloneNode(true);
        c.querySelectorAll('use').forEach(function(u){
        var hr=u.getAttribute('href')||u.getAttribute('xlink:href');
        if(hr&&hr.charAt(0)==='#'){var ref=document.querySelector(hr);if(ref){
        var g=document.createElementNS('http://www.w3.org/2000/svg','g');
        g.innerHTML=ref.innerHTML;u.parentNode.replaceChild(g,u);}}});
        var bb=svg.getBoundingClientRect();
        if(!c.getAttribute('viewBox'))c.setAttribute('viewBox','0 0 '+bb.width+' '+bb.height);
        if(!c.getAttribute('width'))c.setAttribute('width',''+bb.width);
        if(!c.getAttribute('height'))c.setAttribute('height',''+bb.height);
        c.setAttribute('xmlns','http://www.w3.org/2000/svg');
        return c.outerHTML;}
        document.querySelectorAll('svg').forEach(function(s){
        var r=s.getBoundingClientRect();
        if(r.width<4||r.height<4)return;
        var cs=getComputedStyle(s);
        if(cs.display==='none'||cs.visibility==='hidden')return;
        var ex=window.screenX+r.left*z,ey=window.screenY+ch+r.top*z;
        if(hit(ex,ey,r.width*z,r.height*z))R.push(resolve(s));});
        document.querySelectorAll('img').forEach(function(img){
        var src=img.getAttribute('src')||'';
        if(!/\\.svg($|\\?)/i.test(src))return;
        var r=img.getBoundingClientRect();
        if(r.width<4||r.height<4)return;
        var cs=getComputedStyle(img);
        if(cs.display==='none'||cs.visibility==='hidden')return;
        var ex=window.screenX+r.left*z,ey=window.screenY+ch+r.top*z;
        if(!hit(ex,ey,r.width*z,r.height*z))return;
        try{var x=new XMLHttpRequest();x.open('GET',new URL(src,location.href).href,false);
        x.send();if(x.status===200&&x.responseText.indexOf('<svg')!==-1)R.push(x.responseText.trim());}catch(e){}});
        return JSON.stringify(R);})()
        """
    }

    // MARK: - AppleScript

    private static func runBoxes(_ source: String) -> Result<[CGRect], BrowserAutomationFailure> {
        BrowserAutomation.readArray(source) { data in
            let arr = try JSONDecoder().decode([[Double]].self, from: data)
            return try arr.map { item in
                guard item.count == 4, item.allSatisfy({ $0.isFinite }), item[2] > 0, item[3] > 0 else {
                    throw BrowserAutomationFailure(kind: .invalidResponse)
                }
                return CGRect(x: item[0], y: item[1], width: item[2], height: item[3])
            }
        }
    }

    private static func run(_ source: String) -> Result<[String], BrowserAutomationFailure> {
        BrowserAutomation.readArray(source) { try JSONDecoder().decode([String].self, from: $0) }
    }

    // MARK: - Combine multiple SVGs

    private static func combineSVGs(_ svgs: [String], gap: CGFloat = 20) -> String {
        var items: [(svg: String, w: CGFloat, h: CGFloat)] = []
        for svg in svgs {
            let w = dimension(svg, "width") ?? 24
            let h = dimension(svg, "height") ?? 24
            items.append((svg, w, h))
        }
        let totalW = items.reduce(CGFloat(0)) { $0 + $1.w } + gap * CGFloat(items.count - 1)
        let maxH = items.map(\.h).max() ?? 24
        var inner = ""
        var x: CGFloat = 0
        for item in items {
            let y = (maxH - item.h) / 2
            inner += "<g transform=\"translate(\(x),\(y))\">\(item.svg)</g>\n"
            x += item.w + gap
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(totalW) \(maxH)" width="\(totalW)" height="\(maxH)">
        \(inner)</svg>
        """
    }

    private static func dimension(_ svg: String, _ attr: String) -> CGFloat? {
        guard let regex = try? NSRegularExpression(pattern: "\(attr)=[\"']([\\d.]+)"),
              let match = regex.firstMatch(in: svg, range: NSRange(svg.startIndex..., in: svg)),
              let range = Range(match.range(at: 1), in: svg),
              let val = Double(svg[range]) else { return nil }
        return CGFloat(val)
    }
}
#endif
