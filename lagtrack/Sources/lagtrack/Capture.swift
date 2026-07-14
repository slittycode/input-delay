import Foundation
import ScreenCaptureKit
import CoreMedia

struct WindowMatch {
    let window: SCWindow
    let appName: String
    let title: String
    let pid: pid_t
}

enum WindowFinder {
    static func shareableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.filter {
            $0.isOnScreen && $0.frame.width >= 50 && $0.frame.height >= 50
        }
    }

    /// Match by title/app-name substring and/or owning pid; among matches take the
    /// largest window (games are big, Wine helper windows are not).
    static func find(query: String?, pid: pid_t?) async throws -> WindowMatch? {
        let windows = try await shareableWindows()
        let candidates = windows.filter { w in
            if let pid, w.owningApplication?.processID != pid { return false }
            if let query {
                let title = w.title ?? ""
                let app = w.owningApplication?.applicationName ?? ""
                if !title.localizedCaseInsensitiveContains(query),
                   !app.localizedCaseInsensitiveContains(query) {
                    return false
                }
            }
            return true
        }
        guard let best = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return nil }
        return WindowMatch(
            window: best,
            appName: best.owningApplication?.applicationName ?? "?",
            title: best.title ?? "",
            pid: best.owningApplication?.processID ?? 0
        )
    }

    static func printList() async throws {
        let windows = try await shareableWindows()
        let sorted = windows.sorted {
            ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "")
        }
        func pad(_ s: String, _ n: Int) -> String {
            s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
        }
        print("\(pad("PID", 7)) \(pad("APP", 28)) \(pad("SIZE", 11)) TITLE")
        for w in sorted {
            let pid = "\(w.owningApplication?.processID ?? 0)"
            let app = String((w.owningApplication?.applicationName ?? "?").prefix(28))
            let size = "\(Int(w.frame.width))x\(Int(w.frame.height))"
            let title = String((w.title ?? "").prefix(60))
            print("\(pad(pid, 7)) \(pad(app, 28)) \(pad(size, 11)) \(title)")
        }
    }
}

/// Watches one window via ScreenCaptureKit. Output is scaled to a thumbnail —
/// we only care that a new frame was presented and *when*, never about pixels.
final class CaptureEngine: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "lagtrack.capture")
    private var lastDisplayNs: UInt64 = 0

    var onFrame: ((UInt64) -> Void)?
    var onStopped: ((Error?) -> Void)?

    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width = 160
        cfg.height = 90
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        // Never cap the observable rate below what the compositor can deliver.
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        cfg.queueDepth = 5
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        lastDisplayNs = 0
    }

    func stop() async {
        if let s = stream {
            stream = nil
            try? await s.stopCapture()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let displayTicks = info[.displayTime] as? UInt64
        else { return }
        let ns = MachTime.toNs(displayTicks)
        guard ns != lastDisplayNs else { return }
        lastDisplayNs = ns
        onFrame?(ns)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error)
    }
}
