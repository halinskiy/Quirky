import Cocoa

final class SVGExtractor {

    // MARK: - Public

    /// Returns bounding boxes of all visible SVGs on the page in CG coordinates (top-left origin).
    static func getSVGBoundingBoxes(from app: NSRunningApplication?, completion: @escaping ([CGRect]) -> Void) {
        guard let browser = detectBrowser(app) else {
            DispatchQueue.main.async { completion([]) }
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

        let source = appleScript(browser: browser, js: js)

        DispatchQueue.global(qos: .userInitiated).async {
            let boxes = runBoxes(source)
            DispatchQueue.main.async { completion(boxes) }
        }
    }

    static func extractSVGs(in screenRect: CGRect, from app: NSRunningApplication?, completion: @escaping ([String]) -> Void) {
        guard let browser = detectBrowser(app) else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        let js = buildJavaScript(for: screenRect)
        let source = appleScript(browser: browser, js: js)

        DispatchQueue.global(qos: .userInitiated).async {
            let svgs = run(source)
            DispatchQueue.main.async { completion(svgs) }
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

    // MARK: - Browser detection

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

    /// Programmatically enable "Allow JavaScript from Apple Events" for Chromium browsers.
    private static func ensureJSEnabled(bundleID: String) {
        let key = "AppleScriptEnabled"
        if UserDefaults(suiteName: bundleID)?.bool(forKey: key) == true { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", bundleID, key, "-bool", "true"]
        try? task.run()
        task.waitUntilExit()
    }

    /// Programmatically enable "Allow JavaScript from Apple Events" for Safari.
    private static func ensureSafariJSEnabled() {
        let key = "AllowJavaScriptFromAppleEvents"
        if UserDefaults(suiteName: "com.apple.Safari")?.bool(forKey: key) == true { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["write", "com.apple.Safari", key, "-bool", "true"]
        try? task.run()
        task.waitUntilExit()
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

    private static func runBoxes(_ source: String) -> [CGRect] {
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return [] }
        guard let json = result.stringValue,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else { return [] }
        return arr.compactMap { item in
            guard item.count == 4 else { return nil }
            return CGRect(x: item[0], y: item[1], width: item[2], height: item[3])
        }
    }

    private static func run(_ source: String) -> [String] {
        guard let script = NSAppleScript(source: source) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            NSLog("SVGExtractor AppleScript error: \(error)")
            return []
        }
        guard let json = result.stringValue,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
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
