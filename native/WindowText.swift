import AppKit
import ScreenCaptureKit
import Vision

/// Text recognized in the target window, as context for one dictation.
///
/// Used only when 识别窗口文字 is on and Accessibility exposes little visible
/// text (many Electron, canvas and remote-desktop windows expose none). The
/// window image exists only in memory for the recognition: it is never saved
/// and never sent anywhere. The recognized text goes to the local editor as
/// visible text, which the cloud request leaves out.
enum WindowText {
    /// Password managers and the Keychain: their windows are never read.
    static let skipped = ["com.1password", "com.agilebits", "com.bitwarden", "com.lastpass", "com.apple.keychainaccess", "com.apple.passwords"]
    /// Visible text shorter than this from Accessibility is supplemented with recognition.
    static let enough = 200
    static let limit = 4000

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    /// Shows the system prompt the first time; afterwards macOS only lists the app in Settings.
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func allowed(bundle: String) -> Bool {
        !skipped.contains { bundle.lowercased().hasPrefix($0) }
    }

    /// Recognize the window of `pid` that contains `anchor` (the caret), else the
    /// one titled `title`, else its largest window. Calls back on the main
    /// thread with "" when not permitted or on any failure.
    static func recognize(pid: pid_t, bundle: String, title: String, anchor: CGRect?, completion: @escaping (String) -> Void) {
        guard permitted, allowed(bundle: bundle) else { completion(""); return }
        Task.detached(priority: .userInitiated) {
            var text = ""
            if let image = try? await capture(pid: pid, title: title, anchor: anchor) { text = read(image) }
            let result = text
            await MainActor.run { completion(result) }
        }
    }

    private static func capture(pid: pid_t, title: String, anchor: CGRect?) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80
        }
        // Accessibility and ScreenCaptureKit both use global coordinates with a top-left origin.
        let caret = anchor.map { CGPoint(x: $0.midX, y: $0.midY) }
        let window = caret.flatMap { point in windows.first { $0.frame.contains(point) } }
            ?? windows.first { !title.isEmpty && $0.title == title }
            ?? windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let window else { return nil }
        let configuration = SCStreamConfiguration()
        // Enough pixels for small UI text; capped so a 6K window stays cheap.
        let scale = min(2.0, 2600 / max(window.frame.width, window.frame.height))
        configuration.width = Int(window.frame.width * scale); configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    }

    static func read(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        // Top to bottom, then left to right; Vision's boxes have a bottom-left origin.
        let lines = (request.results ?? []).sorted {
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
        }.compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    /// Recognition loads its model on first use (about 18 s on an M4); do that early.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.setFillColor(gray: 1, alpha: 1); context?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            if let image = context?.makeImage() { _ = read(image) }
        }
    }
}
