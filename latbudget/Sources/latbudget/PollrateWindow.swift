import AppKit

final class PollrateWindow: NSObject, NSWindowDelegate {
    let monitor: PollrateMonitor
    private let window: NSWindow
    private let nameField: NSTextField
    private let rateField: NSTextField
    private let rateSubtitle: NSTextField
    private let statsField: NSTextField
    private var timer: DispatchSourceTimer?
    private var emptyStreak = 0

    private let w: CGFloat = 280
    private let h: CGFloat = 230

    init(monitor: PollrateMonitor) {
        self.monitor = monitor

        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2 + 200, width: w, height: h)

        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        let dark = NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)

        nameField = NSTextField(labelWithString: "waiting for controller…")
        rateField = NSTextField(labelWithString: "--")
        rateSubtitle = NSTextField(labelWithString: "polling rate  Hz")
        statsField = NSTextField(labelWithString: "")

        super.init()

        window.title = "Polling Monitor"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating

        nameField.font = .systemFont(ofSize: 12, weight: .medium)
        nameField.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        nameField.alignment = .center
        nameField.frame = NSRect(x: 20, y: h - 46, width: w - 40, height: 18)

        rateField.font = .monospacedDigitSystemFont(ofSize: 42, weight: .bold)
        rateField.textColor = NSColor(calibratedRed: 0.4, green: 1.0, blue: 0.5, alpha: 1)
        rateField.alignment = .center
        rateField.frame = NSRect(x: 20, y: h - 104, width: w - 40, height: 50)

        rateSubtitle.font = .systemFont(ofSize: 10, weight: .regular)
        rateSubtitle.textColor = NSColor(calibratedWhite: 0.4, alpha: 1)
        rateSubtitle.alignment = .center
        rateSubtitle.frame = NSRect(x: 20, y: h - 122, width: w - 40, height: 14)

        statsField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statsField.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        statsField.alignment = .left
        statsField.frame = NSRect(x: 28, y: 16, width: w - 56, height: 96)

        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = dark.cgColor
        content.addSubview(nameField)
        content.addSubview(rateField)
        content.addSubview(rateSubtitle)
        content.addSubview(statsField)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.125)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let s = monitor.snapshot()
        nameField.stringValue = s.deviceCount > 1
            ? "\(s.deviceName)  ·  \(s.transport)  ·  +\(s.deviceCount - 1) other"
            : "\(s.deviceName)  ·  \(s.transport)"
        if s.reports > 0 {
            emptyStreak = 0
            rateField.stringValue = String(format: "%.0f", s.liveRateHz)
            rateField.textColor = rateColor(s.liveRateHz)
            rateSubtitle.stringValue = "polling rate  Hz"
            statsField.stringValue = String(format: """
            Reports  %d
            Median   %5.2f ms
            Jitter   %5.2f ms
            Min      %5.2f ms
            Max      %5.2f ms
            Elapsed  %@
            """, s.reports, s.medianMs, s.jitterMs, s.minMs, s.maxMs, fmtDuration(s.elapsedS))
        } else {
            emptyStreak += 1
            if emptyStreak > 24 {
                rateField.stringValue = "--"
                rateField.textColor = NSColor(calibratedRed: 0.7, green: 0.7, blue: 0.7, alpha: 1)
                rateSubtitle.stringValue = "no reports — move controller"
                statsField.stringValue = "Press buttons, move sticks,\nor rotate the left stick in circles.\n\nReports: 0"
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        let s = monitor.snapshot()
        if s.reports > 0 {
            printSnapshotJSON(s)
        }
        timer?.cancel()
        exit(0)
    }
}

private func rateColor(_ hz: Double) -> NSColor {
    if hz >= 250 { return NSColor(calibratedRed: 0.4, green: 1.0, blue: 0.5, alpha: 1) }
    if hz >= 125 { return NSColor(calibratedRed: 0.6, green: 1.0, blue: 0.35, alpha: 1) }
    if hz >= 60  { return .systemYellow }
    return .systemRed
}

private func fmtDuration(_ s: Double) -> String {
    let t = Int(s)
    return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
}

func printSnapshotJSON(_ s: PollrateMonitor.Snapshot) {
    struct Intervals: Codable {
        let min: Double
        let median: Double
        let avg: Double
        let max: Double
        let jitter_std: Double
    }
    struct PollResult: Codable {
        let tool: String
        let controller: String
        let transport: String
        let device_count: Int
        let duration_s: Double
        let reports_captured: Int
        let intervals_captured: Int
        let polling_rate_hz: Double
        let interval_ms: Intervals
    }
    let result = PollResult(
        tool: "latbudget-hid-poll",
        controller: s.deviceName,
        transport: s.transport,
        device_count: s.deviceCount,
        duration_s: (s.elapsedS * 100).rounded() / 100,
        reports_captured: s.reports,
        intervals_captured: s.intervals,
        polling_rate_hz: (s.pollingRateHz * 10).rounded() / 10,
        interval_ms: Intervals(
            min: (s.minMs * 1000).rounded() / 1000,
            median: (s.medianMs * 1000).rounded() / 1000,
            avg: round3(s.avgMs),
            max: (s.maxMs * 1000).rounded() / 1000,
            jitter_std: (s.jitterMs * 1000).rounded() / 1000
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? encoder.encode(result), let str = String(data: d, encoding: .utf8) {
        print(str)
    }
}
