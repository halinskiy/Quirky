import Cocoa

// `Quirky --ocr <png>`: one-shot recognition in a fresh process, used when
// Vision has broken inside the long-running app (see OCREngine.recognizeText).
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ocr" {
    exit(OCREngine.runOneShot(path: CommandLine.arguments[2]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
