import Foundation
import AppKit

let usageText = """
latbudget — CrossOver input-latency BUDGET monitor (macOS, Apple Silicon).

Reports a PER-STAGE budget with explicit unmeasured gaps. It never prints a single
"input lag: X ms" number, because software cannot measure button-to-photon.

USAGE:
  latbudget --selftest              prove the harness resolves a 1000 Hz source
  latbudget                         stages B (+C if the in-bottle proxy is running)
  latbudget "<window substring>"    stages B, C and D (D = presents of that window)
  latbudget --port <n>              UDP port for the in-bottle proxy (default 4517)
  latbudget --pollrate [--duration 15] [--out result.json]
                         measure raw controller polling rate via IOHID (no caps)
  latbudget --pollrate --gui
                         live dashboard window — any controller, any input

Stage C requires the proxy DLL inside the bottle — see wine/install-proxy.sh.
Ctrl-C prints the budget.
"""

struct Options {
    var selftest = false
    var query: String?
    var port: UInt16 = 4517
    var pollrate = false
    var gui = false
    var pollDuration = 15
    var pollOut: String? = nil
}

func parseArgs(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--selftest": o.selftest = true
        case "--port":
            i += 1
            guard i < args.count, let p = UInt16(args[i]) else { fatalError("--port needs a number") }
            o.port = p
        case "--pollrate": o.pollrate = true
        case "--gui": o.gui = true
        case "--duration":
            i += 1
            guard i < args.count, let d = Int(args[i]), d > 0 else { fatalError("--duration needs a positive number of seconds") }
            o.pollDuration = d
        case "--out":
            i += 1
            guard i < args.count else { fatalError("--out needs a path") }
            o.pollOut = args[i]
        case "-h", "--help":
            print(usageText)
            exit(0)
        default:
            o.query = args[i]
        }
        i += 1
    }
    return o
}

/// Joins the stages: host HID reports ↔ bottle packet-changes ↔ presents.
final class Correlator {
    private let lock = NSLock()
    private var hidTimes: [UInt64] = []
    private var pendingPresent: [UInt64] = []
    private var cSamplesMs: [Double] = []
    private var dSamplesMs: [Double] = []

    func hidReport(_ ns: UInt64) {
        lock.lock()
        hidTimes.append(ns)
        if hidTimes.count > 512 { hidTimes.removeFirst(256) }
        lock.unlock()
    }

    func bottleEvent(_ ns: UInt64) {
        lock.lock()
        // Stage C: nearest preceding host HID report within 100 ms.
        if let t = hidTimes.last(where: { $0 <= ns && ns - $0 < 100_000_000 }) {
            cSamplesMs.append(Double(ns - t) / 1e6)
            if cSamplesMs.count > 100_000 { cSamplesMs.removeFirst(50_000) }
        }
        pendingPresent.append(ns)
        if pendingPresent.count > 64 { pendingPresent.removeFirst(32) }
        lock.unlock()
    }

    func present(_ ns: UInt64) {
        lock.lock()
        if !pendingPresent.isEmpty {
            var remaining: [UInt64] = []
            for t in pendingPresent {
                if t < ns {
                    let ms = Double(ns - t) / 1e6
                    if ms <= 5000 { dSamplesMs.append(ms) }
                } else {
                    remaining.append(t)
                }
            }
            pendingPresent = remaining
            if dSamplesMs.count > 100_000 { dSamplesMs.removeFirst(50_000) }
        }
        lock.unlock()
    }

    func snapshot() -> (c: [Double], d: [Double]) {
        lock.lock()
        defer { lock.unlock() }
        return (cSamplesMs.sorted(), dSamplesMs.sorted())
    }
}

func fmtStage(_ label: String, _ sorted: [Double], extra: String = "") -> String {
    guard !sorted.isEmpty else { return "\(label): no samples yet\(extra)" }
    return String(format: "%@: median %6.2f ms  p99 %6.2f ms  jitter σ %5.2f ms  (n=%d)%@",
                  label, percentile(sorted, 0.50), percentile(sorted, 0.99),
                  stddev(sorted), sorted.count, extra)
}

final class Monitor {
    let opts: Options
    let hid = HIDStage()
    let link = BottleLink()
    let present = PresentStage()
    let correlator = Correlator()
    var presentAttached = false
    var timer: DispatchSourceTimer?
    var sigintSource: DispatchSourceSignal?
    var finishing = false

    init(opts: Options) {
        self.opts = opts
    }

    func start() {
        hid.onReport = { [correlator] ns in correlator.hidReport(ns) }
        guard hid.start() else {
            FileHandle.standardError.write(Data("latbudget: IOHIDManagerOpen failed — grant Input Monitoring to this terminal and relaunch.\n".utf8))
            exit(1)
        }
        link.onPacketChange = { [correlator] ev in correlator.bottleEvent(ev.machNs) }
        guard link.start(port: opts.port) else {
            FileHandle.standardError.write(Data("latbudget: cannot bind UDP 127.0.0.1:\(opts.port)\n".utf8))
            exit(1)
        }
        print("latbudget: stage B armed (HID), stage C listening on udp://127.0.0.1:\(opts.port)")

        if let query = opts.query {
            present.onPresent = { [correlator] ns in correlator.present(ns) }
            Task {
                do {
                    if try await present.attach(query: query) {
                        print("latbudget: stage D armed — presents of [\(present.appName)] \"\(present.windowTitle)\"")
                        self.presentAttached = true
                    } else {
                        print("latbudget: no window matches \"\(query)\" — running without stage D")
                    }
                } catch {
                    print("latbudget: stage D unavailable (\(error.localizedDescription)) — check Screen Recording permission")
                }
            }
        }
        installSignalHandler()
        startTicker()
    }

    private func startTicker() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        var parts: [String] = []
        for (name, s) in hid.summaries() {
            parts.append(String(format: "[B]%@ med %.1fms σ %.2fms n=%d",
                                String(name.prefix(12)), s.medianMs, s.jitterMs, s.n))
        }
        if parts.isEmpty { parts.append("[B] waiting for gamepad reports") }
        let (c, d) = correlator.snapshot()
        parts.append(link.helloSeen
            ? String(format: "[C] rx %d chg %d med %.1fms poll %.0fHz",
                     link.packetsReceived, link.changeEvents, percentile(c, 0.5), link.lastPollRateHz)
            : "[C] no proxy")
        if presentAttached {
            parts.append(String(format: "[D] med %.1fms n=%d", percentile(d, 0.5), d.count))
        }
        print(parts.joined(separator: " | "))
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in self?.finish() }
        src.resume()
        sigintSource = src
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        timer?.cancel()
        let (c, d) = correlator.snapshot()
        let presents = present.presentSummary()

        print("""

        ════════ INPUT LATENCY BUDGET ════════
        Per-stage, measured where measurable, UNMEASURED stated where not.
        These stages are deliberately NOT summed into one number.

        [A] in-controller scan + radio transmit ............ UNMEASURED (hardware)
            context: BT LE connection intervals are typically 7.5–15 ms; wired USB
            polls at 1–8 ms. Not observable in software from the host side.
        """)
        let sums = hid.summaries()
        if sums.isEmpty {
            print("[B] host HID report cadence ....................... no gamepad reports captured")
        } else {
            print("[B] host HID report cadence (kernel report timestamps)")
            for (name, s) in sums {
                print(String(format: "    %@: median %.2f ms  p99 %.2f ms  jitter σ %.2f ms  max %.1f ms",
                             name, s.medianMs, s.p99Ms, s.jitterMs, s.maxMs))
                print(String(format: "      reports %d, idle gaps %d (still stick sends nothing — gaps excluded from cadence)",
                             s.reports, s.idleGaps))
                print(String(format: "      waiting cost for a random press ≈ uniform 0..interval → mean ≈ %.1f ms",
                             s.medianMs / 2))
                print(String(format: "      harness delivery lag: p50 %.0f µs  p99 %.0f µs (see --selftest)",
                             s.lagP50Us, s.lagP99Us))
            }
        }
        if c.isEmpty {
            print("[C] host HID → XInput packet at game poll ......... no samples"
                + (link.helloSeen ? "" : " (proxy not connected — wine/install-proxy.sh)"))
        } else {
            print(fmtStage("[C] host HID → XInput packet at game poll", c,
                           extra: String(format: "\n      includes bottle transport + wait for the game's own poll; clock sync ±%.1f ms",
                                         link.syncBoundMs())))
        }
        if d.isEmpty {
            print("[D] game-observed packet → next present ........... no samples"
                + (presentAttached ? "" : " (no window attached)"))
        } else {
            print(fmtStage("[D] game-observed packet → next present", d))
            print("      UNMEASURED inside [D]: the presented frame need not contain the input's")
            print("      effect — games pipeline 1–3 frames. This is a lower bound.")
        }
        if presents.n > 0 {
            print(String(format: "[E] present → photon ............................... UNMEASURED\n      bound: ≤ 1 present interval (median %.1f ms observed) + panel response.",
                         presents.medianMs))
        } else {
            print("[E] present → photon ............................... UNMEASURED (display scanout + panel)")
        }
        print("══════════════════════════════════════")
        exit(0)
    }
}

func runPollrate(_ opts: Options) {
    if opts.gui { runPollrateGUI(opts); return }

    let mon = PollrateMonitor()
    guard mon.start() else {
        fputs("latbudget: IOHIDManagerOpen failed — grant Input Monitoring permission.\n", stderr)
        exit(1)
    }
    fputs("latbudget: listening (\(opts.pollDuration)s) — use ANY controller input…\n", stderr)

    var finished = false
    let finish: () -> Void = {
        guard !finished else { return }
        finished = true
        let snap = mon.snapshot()
        if let outPath = opts.pollOut {
            let intervals = IntervalsJSON(
                min: round3(snap.minMs), median: round3(snap.medianMs),
                avg: round3(snap.avgMs), max: round3(snap.maxMs),
                jitter_std: round3(snap.jitterMs)
            )
            let r = PollResult(tool: "latbudget-hid-poll", controller: snap.deviceName,
                                transport: snap.transport, device_count: snap.deviceCount,
                               duration_s: round1(snap.elapsedS), reports_captured: snap.reports,
                               intervals_captured: snap.intervals,
                               polling_rate_hz: round1(snap.pollingRateHz),
                               interval_ms: intervals)
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? e.encode(r) { try? d.write(to: URL(fileURLWithPath: outPath)) }
            fputs("latbudget: wrote result to \(outPath)\n", stderr)
        } else {
            printSnapshotJSON(snap)
        }
        exit(0)
    }

    signal(SIGINT, SIG_IGN)
    let sigsrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigsrc.setEventHandler(handler: finish)
    sigsrc.resume()

    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
        if !finished && mon.snapshot().reports == 0 {
            fputs("latbudget: no controller reports after 3s — is a gamepad connected?\n", stderr)
            exit(1)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(opts.pollDuration), execute: finish)
    RunLoop.main.run()
}

func runPollrateGUI(_ opts: Options) {
    let mon = PollrateMonitor()
    guard mon.start() else {
        fputs("latbudget: IOHIDManagerOpen failed — grant Input Monitoring permission.\n", stderr)
        exit(1)
    }
    let win = PollrateWindow(monitor: mon)
    win.show()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.run()
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
    let interval_ms: IntervalsJSON
}

struct IntervalsJSON: Codable {
    let min: Double
    let median: Double
    let avg: Double
    let max: Double
    let jitter_std: Double
}

func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

setvbuf(stdout, nil, _IONBF, 0) // logs must stream when piped
// SCContentFilter needs a window-server connection; bare CLIs crash without one.
_ = NSApplication.shared

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))

if opts.selftest {
    exit(SelfTest.run() ? 0 : 1)
}

if opts.pollrate {
    runPollrate(opts)
    // never returns
}

let monitor = Monitor(opts: opts)
monitor.start()
RunLoop.main.run()
