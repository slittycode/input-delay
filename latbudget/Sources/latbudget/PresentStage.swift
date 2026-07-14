import Foundation
import ScreenCaptureKit
import CoreMedia

/// STAGE D boundary — compositor presents of the game window via ScreenCaptureKit,
/// timestamped by the frame's own `displayTime` (mach ticks), not callback arrival.
final class PresentStage: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "latbudget.capture")
    private var lastDisplayNs: UInt64 = 0

    private(set) var windowTitle = ""
    private(set) var appName = ""
    var onPresent: ((UInt64) -> Void)?

    /// Median present interval over the session — used only to state the [E] bound.
    private let series = IntervalSeries(gapMs: 1000)

    func attach(query: String) async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { w in
            guard w.isOnScreen, w.frame.width >= 50, w.frame.height >= 50 else { return false }
            let title = w.title ?? ""
            let app = w.owningApplication?.applicationName ?? ""
            return title.localizedCaseInsensitiveContains(query) || app.localizedCaseInsensitiveContains(query)
        }
        guard let win = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else { return false }
        windowTitle = win.title ?? ""
        appName = win.owningApplication?.applicationName ?? "?"

        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        cfg.width = 160
        cfg.height = 90
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        cfg.queueDepth = 5
        cfg.showsCursor = false
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        return true
    }

    func presentSummary() -> SeriesSummary {
        series.summary()
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
        series.ingest(eventNs: ns, arrivalNs: MachTime.nowNs())
        onPresent?(ns)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("latbudget: [D] capture stream stopped (\(error.localizedDescription)) — stage D paused")
        self.stream = nil
    }
}
