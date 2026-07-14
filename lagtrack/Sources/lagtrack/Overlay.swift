import AppKit

/// Metal-HUD-style on-screen stats bar: a borderless, click-through, non-activating
/// panel at the top of the main display. It never takes focus, so the game keeps
/// keyboard/controller input, and it floats above fullscreen Spaces.
final class Overlay {
    private let panel: NSPanel
    private let label: NSTextField
    private let latLabel: NSTextField

    init() {
        NSApp.setActivationPolicy(.accessory)
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 1000
        let h: CGFloat = 26
        let latW: CGFloat = 130
        let rect = NSRect(x: screen.midX - w / 2, y: screen.maxY - h - 2, width: w, height: h)

        panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        label = NSTextField(labelWithString: "lagtrack — waiting for frames…")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.4, green: 1.0, blue: 0.5, alpha: 1)
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 4, width: w - latW - 16, height: 17)
        panel.contentView?.addSubview(label)

        latLabel = NSTextField(labelWithString: "")
        latLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        latLabel.alignment = .right
        latLabel.frame = NSRect(x: w - latW - 8, y: 4, width: latW, height: 17)
        panel.contentView?.addSubview(latLabel)

        panel.orderFrontRegardless()
    }

    func update(_ text: String) {
        label.stringValue = text
    }

    /// Instant per-press readout: shows the latest input→present sample the moment
    /// it resolves, color-coded (green < 40 ms, yellow < 80 ms, red beyond).
    func showLatency(_ ms: Double, kind: InputKind) {
        latLabel.stringValue = String(format: "%@ %.0f ms", kind == .controller ? "🎮" : "⌨", ms)
        latLabel.textColor = ms < 40
            ? NSColor(calibratedRed: 0.4, green: 1.0, blue: 0.5, alpha: 1)
            : (ms < 80 ? .systemYellow : .systemRed)
    }
}
