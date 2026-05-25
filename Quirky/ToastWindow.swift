import Cocoa
import CoreText

enum ToastStyle {
    case normal
    case error

    var bgColor: CGColor {
        switch self {
        case .normal: return NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0.7).cgColor
        case .error:  return NSColor(deviceRed: 0.85, green: 0.18, blue: 0.18, alpha: 0.95).cgColor
        }
    }

    var dwellSeconds: Double {
        switch self {
        case .normal: return 0.8
        case .error:  return 2.0
        }
    }
}

final class ToastWindow: NSWindow {
    private static var current: ToastWindow?

    // macOS 26: avoid NSFont.systemFont (lazy CTFontDescriptor) and catalog NSColors
    // in attribute dicts — Core Text crashes copying nil internal entries.
    private static let toastFont: CTFont = {
        if let f = CGFont("Helvetica-Bold" as CFString) { return CTFontCreateWithGraphicsFont(f, 13, nil, nil) }
        return CTFontCreateWithName("Helvetica" as CFString, 13, nil)
    }()
    private static let toastTextColor: CGColor =
        NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).cgColor

    static func show(_ message: String, style: ToastStyle = .normal) {
        current?.orderOut(nil)

        let line = makeLine(message)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let hPad: CGFloat = 16
        let vPad: CGFloat = 8
        let width = textBounds.width + hPad * 2
        let height = textBounds.height + vPad * 2

        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.midY - height / 2 - screen.frame.height * 0.2
        let frame = NSRect(x: x, y: y, width: width, height: height)

        let toast = ToastWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        toast.level = .init(Int(CGShieldingWindowLevel()) + 1)
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = false
        toast.ignoresMouseEvents = true
        toast.collectionBehavior = [.canJoinAllSpaces, .transient]
        toast.isReleasedWhenClosed = false

        let view = ToastView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            line: line, textBounds: textBounds, bgColor: style.bgColor
        )
        toast.contentView = view

        toast.alphaValue = 0
        toast.orderFrontRegardless()

        current = toast

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toast.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + style.dwellSeconds) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                toast.animator().alphaValue = 0
            }, completionHandler: {
                toast.orderOut(nil)
                if current === toast { current = nil }
            })
        }
    }

    fileprivate static func makeLine(_ string: String) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: toastFont,
            kCTForegroundColorAttributeName as NSAttributedString.Key: toastTextColor
        ]
        let attrString = NSAttributedString(string: string, attributes: attrs)
        return CTLineCreateWithAttributedString(attrString as CFAttributedString)
    }
}

private final class ToastView: NSView {
    let line: CTLine
    let textBounds: CGRect
    let bgColor: CGColor

    init(frame: NSRect, line: CTLine, textBounds: CGRect, bgColor: CGColor) {
        self.line = line
        self.textBounds = textBounds
        self.bgColor = bgColor
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let bgPath = CGPath(
            roundedRect: bounds, cornerWidth: bounds.height / 2,
            cornerHeight: bounds.height / 2, transform: nil
        )
        context.addPath(bgPath)
        context.setFillColor(bgColor)
        context.fillPath()

        let x = (bounds.width - textBounds.width) / 2 - textBounds.minX
        let y = (bounds.height - textBounds.height) / 2 - textBounds.minY
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
