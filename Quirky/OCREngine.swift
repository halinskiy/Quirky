import Vision
import AppKit

final class OCREngine {
    /// Vision loads its accurate text model lazily, and on a busy Mac the first
    /// request has taken 30–40 s, long enough that the user gives up and the
    /// result lands on the clipboard (or fails) after they've moved on. Load it
    /// at launch instead so the first real capture is instant.
    private static var keepWarmTimer: Timer?
    private static var warming = false

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

    static func warmUp() {
        guard !warming else { return }
        warming = true
        guard let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = ctx.makeImage() else { return }
        DispatchQueue.global(qos: .utility).async {
            let start = Date()
            let request = makeRequest(level: .accurate) { _, _ in }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            catch { captureLog.error("OCR warm-up failed: \(String(describing: error), privacy: .public)") }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if ms > 500 { captureLog.notice("OCR warm-up took \(ms, privacy: .public) ms") }
            DispatchQueue.main.async { warming = false }
        }
    }

    static func recognizeText(in image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Accurate first; if Vision errors out (it has, silently, under
            // load) fall back to the fast recognizer rather than report "no text".
            var text = run(image, level: .accurate)
            if text == nil { text = run(image, level: .fast) }
            DispatchQueue.main.async { completion(text ?? "") }
        }
    }

    /// nil means the request failed; "" means it ran and found nothing.
    private static func run(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> String? {
        var result: String?
        let request = makeRequest(level: level) { request, error in
            if let error {
                captureLog.error("OCR \(level == .fast ? "fast" : "accurate", privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            result = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            captureLog.error("OCR perform threw: \(String(describing: error), privacy: .public)")
            return nil
        }
        return result
    }

    private static func makeRequest(level: VNRequestTextRecognitionLevel,
                                    completion: @escaping VNRequestCompletionHandler) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest(completionHandler: completion)
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
            request.automaticallyDetectsLanguage = true
        }
        return request
    }
}
