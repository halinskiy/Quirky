import CoreGraphics

final class ScreenCapture {
    /// Captures a screen region specified in CG coordinate space (origin top-left).
    /// Excludes the overlay window if a window number is provided.
    static func capture(rect: CGRect, excludingWindow windowNumber: CGWindowID = kCGNullWindowID) -> CGImage? {
        if windowNumber != kCGNullWindowID {
            return CGWindowListCreateImage(
                rect,
                .optionOnScreenBelowWindow,
                windowNumber,
                [.bestResolution, .boundsIgnoreFraming]
            )
        } else {
            return CGWindowListCreateImage(
                rect,
                .optionOnScreenOnly,
                kCGNullWindowID,
                [.bestResolution, .boundsIgnoreFraming]
            )
        }
    }
}
