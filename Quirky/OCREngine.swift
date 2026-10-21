import Vision
import AppKit

final class OCREngine {
    /// Recognizes text in `image` and calls `completion` exactly once, on the
    /// main thread — with "" when recognition fails or can't even start.
    static func recognizeText(in image: CGImage, completion: @escaping (String) -> Void) {
        // Vision calls the request handler with an error when `perform`
        // throws, but that isn't a documented guarantee. Deliver from both
        // paths and let the first one win; both arrive on the main thread.
        var delivered = false
        func deliver(_ text: String) {
            guard !delivered else { return }
            delivered = true
            completion(text)
        }

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                DispatchQueue.main.async { deliver("") }
                return
            }

            let text = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: "\n")

            DispatchQueue.main.async { deliver(text) }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                NSLog("Quirky: OCR request failed to run: \(error)")
                DispatchQueue.main.async { deliver("") }
            }
        }
    }
}
