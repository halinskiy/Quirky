import Vision
import AppKit
import CoreML

final class OCREngine {
    /// Every Vision call runs here, one at a time: it keeps warm-ups and real
    /// requests from loading the model twice and guards `deviceIndex`.
    private static let queue = DispatchQueue(label: "com.threempq.quirky.ocr", qos: .userInitiated)
    private static var keepWarmTimer: Timer?

    /// Compute devices to try for the accurate model, best first. The Neural
    /// Engine has been seen to break inside a long-running Quirky (every
    /// request failing with e5rtError until relaunch), and the old fallback,
    /// the fast recognizer, can't read Cyrillic: "Мышь дорама" came back as
    /// "MblWb AopaMa". So step down to the GPU, then the CPU, and stay on the
    /// first device that works.
    private static var deviceIndex = 0
    private static let deviceNames = ["default", "gpu", "cpu"]

    /// macOS drops the model again after a while idle (a launch warm-up was
    /// gone 18 minutes later and the next capture waited 16 s). Re-touch it
    /// every few minutes; a 64×32 blank image costs a few milliseconds.
    static func keepWarm() {
        warmUp()
        keepWarmTimer?.invalidate()
        let t = Timer(timeInterval: 240, repeats: true) { _ in warmUp() }
        RunLoop.main.add(t, forMode: .common)
        keepWarmTimer = t
    }

    /// Vision loads its accurate text model lazily, and on a busy Mac the first
    /// request has taken 30–70 s. Load it ahead of the capture instead. The
    /// image has to contain real text: on a blank one the detector finds
    /// nothing and the recognizer, the slow part, is never loaded at all.
    static func warmUp() {
        guard let image = warmUpImage else { return }
        queue.async {
            let start = Date()
            _ = recognizeAccurate(image)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if ms > 500 { captureLog.notice("OCR warm-up took \(ms, privacy: .public) ms") }
        }
    }

    private static let warmUpImage: CGImage? = {
        let size = CGSize(width: 480, height: 64)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        // Named CTFont, not a system-font lookup: see the macOS 26 CoreText note in the HUD code.
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attrs = [kCTFontAttributeName: font,
                     kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1)] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "Прогрев Quirky 2026" as CFString, attrs))
        ctx.textPosition = CGPoint(x: 16, y: 20)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }()

    static func recognizeText(in image: CGImage, completion: @escaping (String) -> Void) {
        queue.async {
            // The fast recognizer is the very last resort: Latin only.
            let text = recognizeAccurate(image) ?? run(image, level: .fast, device: nil)
            DispatchQueue.main.async { completion(text ?? "") }
        }
    }

    /// Accurate recognition on the current device, stepping down on failure.
    /// nil only when every device failed.
    private static func recognizeAccurate(_ image: CGImage) -> String? {
        while deviceIndex < deviceNames.count {
            if let text = run(image, level: .accurate, device: deviceIndex) { return text }
            guard deviceIndex + 1 < deviceNames.count else { break }
            deviceIndex += 1
            captureLog.error("OCR switching to \(deviceNames[deviceIndex], privacy: .public)")
        }
        return nil
    }

    /// nil means the request failed; "" means it ran and found nothing.
    private static func run(_ image: CGImage, level: VNRequestTextRecognitionLevel, device: Int?) -> String? {
        var result: String?
        let request = VNRecognizeTextRequest { request, error in
            if let error {
                captureLog.error("OCR \(level == .fast ? "fast" : "accurate", privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            result = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
            request.automaticallyDetectsLanguage = true
        }
        if let device, device > 0 { pin(request, to: deviceNames[device]) }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            captureLog.error("OCR perform threw: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result
    }

    private static func pin(_ request: VNRecognizeTextRequest, to name: String) {
        guard #available(macOS 14.0, *),
              let stages = try? request.supportedComputeStageDevices else { return }
        let device = MLComputeDevice.allComputeDevices.first {
            switch $0 {
            case .gpu: return name == "gpu"
            case .cpu: return name == "cpu"
            default: return false
            }
        }
        guard let device else { return }
        for stage in stages.keys { request.setComputeDevice(device, for: stage) }
    }
}
