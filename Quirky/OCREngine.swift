import Vision
import AppKit

final class OCREngine {
    static func recognizeText(in image: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                DispatchQueue.main.async { completion("") }
                return
            }

            let text = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: "\n")

            DispatchQueue.main.async { completion(text) }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        if #available(macOS 13.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            try? handler.perform([request])
        }
    }
}
