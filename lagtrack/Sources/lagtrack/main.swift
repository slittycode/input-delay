import Foundation
import AppKit
import ScreenCaptureKit

let usageText = """
lagtrack — live FPS / frametime / input-delay tracker for CrossOver (and any) macOS games.
External measurement only: no injection, no Wine hooks.

USAGE:
  lagtrack --list                         list capturable windows
  lagtrack "<title or app substring>"     attach and start tracking
  lagtrack --pid <pid>                    attach by owning process id

OPTIONS:
  --overlay         Metal-HUD-style on-screen stats bar (click-through, never steals focus)
  --fps-only        no input tap (skips the Input Monitoring permission)
  --no-focus-gate   record inputs even when the game is not the frontmost app
  --csv <path>      per-second log (default: sessions/<timestamp>.csv)

PERMISSIONS (System Settings → Privacy & Security, grant to your terminal, then relaunch):
  Screen Recording   — required (frame timing via ScreenCaptureKit)
  Input Monitoring   — required unless --fps-only

Input delay is measured keyboard/mouse event → next presented frame. Controller
events are invisible to background tools on this Mac (see project NOTES.md);
for controller button-to-photon use the stage2 video method.
"""

struct Options {
    var list = false
    var pid: pid_t?
    var query: String?
    var fpsOnly = false
    var noFocusGate = false
    var overlay = false
    var csvPath: String?
}

func parseArgs(_ args: [String]) -> Options {
    var o = Options()
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--list": o.list = true
        case "--fps-only": o.fpsOnly = true
        case "--no-focus-gate": o.noFocusGate = true
        case "--overlay": o.overlay = true
        case "--pid":
            i += 1
            guard i < args.count, let p = Int32(args[i]) else { fail("--pid needs a number") }
            o.pid = p
        case "--csv":
            i += 1
            guard i < args.count else { fail("--csv needs a path") }
            o.csvPath = args[i]
        case "-h", "--help":
            print(usageText)
            exit(0)
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)") }
            o.query = a
        }
        i += 1
    }
    return o
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("lagtrack: " + msg + "\n").utf8))
    exit(2)
}

func fmtDuration(_ s: Double) -> String {
    let t = Int(s)
    return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
}

// MARK: - Session

final class SessionController {
    let opts: Options
    let tracker = Tracker()
    let capture = CaptureEngine()
    var tap: InputTap?
    var controllerTap: ControllerTap?
    var procMon: ProcMonitor?
    var csv: CSVWriter?
    var match: WindowMatch?
    var timer: DispatchSourceTimer?
    var overlay: Overlay?
    var lastTickNs: UInt64 = 0
    let isTTY = isatty(1) != 0
    var finishing = false

    init(opts: Options) {
        self.opts = opts
    }

    func start() {
        Task { await run() }
    }

    private func run() async {
        let match: WindowMatch
        do {
            guard let m = try await WindowFinder.find(query: opts.query, pid: opts.pid) else {
                fail("no capturable window matches — try `lagtrack --list`")
            }
            match = m
        } catch {
            fail("cannot enumerate windows: \(error.localizedDescription)\nGrant Screen Recording to your terminal in System Settings → Privacy & Security, then relaunch.")
        }
        self.match = match
        self.procMon = ProcMonitor(pid: match.pid)

        capture.onFrame = { [tracker] ns in tracker.recordFrame(displayNs: ns) }
        capture.onStopped = { [weak self] err in
            DispatchQueue.main.async { self?.handleStreamStop(err) }
        }
        do {
            try await capture.start(window: match.window)
        } catch {
            fail("cannot capture window: \(error.localizedDescription)\nGrant Screen Recording to your terminal in System Settings → Privacy & Security, then relaunch.")
        }
        startTicker()
        if opts.overlay {
            DispatchQueue.main.async { self.overlay = Overlay() }
            tracker.onLatencySample = { [weak self] ms, kind in
                DispatchQueue.main.async { self?.overlay?.showLatency(ms, kind: kind) }
            }
        }

        let csvPath = opts.csvPath ?? {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            return "sessions/\(f.string(from: Date())).csv"
        }()
        csv = CSVWriter(path: csvPath)

        print("lagtrack: attached to [\(match.appName)] \"\(match.title)\" (pid \(match.pid), \(Int(match.window.frame.width))x\(Int(match.window.frame.height)))")
        if let csv { print("lagtrack: logging to \(csv.path)") }

        if !opts.fpsOnly {
            let gamePid = match.pid
            let gateOff = opts.noFocusGate
            let gate = {
                gateOff || NSWorkspace.shared.frontmostApplication?.processIdentifier == gamePid
            }
            tap = InputTap(
                handler: { [tracker] ns in tracker.recordInput(ns: ns, kind: .keyboardMouse) },
                shouldRecord: gate
            )
            controllerTap = ControllerTap(
                handler: { [tracker] ns in tracker.recordInput(ns: ns, kind: .controller) },
                shouldRecord: gate
            )
            if tap == nil, controllerTap == nil {
                print("lagtrack: WARNING — no Input Monitoring permission; running FPS-only.")
                print("          Grant it in System Settings → Privacy & Security → Input Monitoring, then relaunch.")
            } else {
                let sources = [tap != nil ? "KB/M" : nil, controllerTap != nil ? "controller" : nil]
                    .compactMap { $0 }.joined(separator: " + ")
                print("lagtrack: input tap active (\(sources); events count only while the game is frontmost)")
            }
        }
        print("lagtrack: Ctrl-C for session summary\n")

        installSignalHandler()
    }

    private func startTicker() {
        lastTickNs = MachTime.nowNs()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = MachTime.nowNs()
        let elapsed = Double(now - lastTickNs) / 1e9
        lastTickNs = now
        let w = tracker.drainWindow(elapsedS: elapsed)
        let p = procMon?.sample()
        csv?.append(w, proc: p)

        var line = String(format: "FPS %6.1f | ft p95 %6.2fms | max %6.1fms", w.fps, w.ftP95, w.ftMax)
        if tap != nil || controllerTap != nil {
            if w.inputs > 0 {
                line += String(format: " | in→present p50 %5.1fms (n=%d)", w.latP50, w.inputs)
            } else {
                line += " | in→present     --      "
            }
        }
        if let p {
            let mem = p.footprintGB >= 1 ? String(format: "%.1fG", p.footprintGB)
                                         : String(format: "%.0fM", p.footprintGB * 1000)
            line += String(format: " | CPU %4.0f%% | mem %@", p.cpuPercent, mem)
        }
        overlay?.update(line)
        if isTTY {
            print("\r\u{1B}[2K" + line, terminator: "")
            fflush(stdout)
        } else {
            print(line)
        }
    }

    private func handleStreamStop(_ error: Error?) {
        guard !finishing else { return }
        if isTTY { print("") }
        print("lagtrack: capture stream stopped (\(error?.localizedDescription ?? "window gone")) — reattaching…")
        Task { await reattach() }
    }

    /// Games recreate their window on resolution / fullscreen changes;
    /// chase the same query for up to 30 s before giving up.
    private func reattach() async {
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let m = try? await WindowFinder.find(query: opts.query, pid: opts.pid),
               (try? await capture.start(window: m.window)) != nil {
                self.match = m
                self.procMon = ProcMonitor(pid: m.pid)
                tracker.markDiscontinuity()
                print("lagtrack: reattached to [\(m.appName)] \"\(m.title)\" (pid \(m.pid))")
                return
            }
        }
        print("lagtrack: window did not come back — ending session")
        finish()
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { [weak self] in self?.finish() }
        src.resume()
        // keep alive for the life of the process
        sigintSource = src
    }

    private var sigintSource: DispatchSourceSignal?

    func finish() {
        guard !finishing else { return }
        finishing = true
        timer?.cancel()
        let s = tracker.sessionSummary()
        csv?.close()
        if isTTY { print("") }
        print("\n── lagtrack session summary ─────────────────────────")
        if let m = match {
            print("window     [\(m.appName)] \"\(m.title)\" (pid \(m.pid))")
        }
        print(String(format: "duration   %@   frames %d", fmtDuration(s.durationS), s.frames))
        print(String(format: "FPS        avg %.1f   1%% low %.1f", s.avgFps, s.onePercentLowFps))
        print(String(format: "frametime  p50 %.2fms  p95 %.2fms  p99 %.2fms  max %.1fms", s.ftP50, s.ftP95, s.ftP99, s.ftMax))
        if s.latencies > 0 {
            print(String(format: "in→present p50 %.1fms  p95 %.1fms  (n=%d, lower-bound proxy)", s.latP50, s.latP95, s.latencies))
        } else if tap != nil || controllerTap != nil {
            print("in→present no samples (no input while the game was frontmost)")
        }
        if let csv { print("csv        \(csv.path)") }
        print("─────────────────────────────────────────────────────")
        Task {
            await capture.stop()
            exit(0)
        }
    }
}

// MARK: - Entry

// SCContentFilter needs a window-server connection that bare CLI processes lack
// (crashes with CGS_REQUIRE_INIT otherwise); touching NSApplication creates one.
_ = NSApplication.shared

let opts = parseArgs(Array(CommandLine.arguments.dropFirst()))

if opts.list {
    Task {
        do {
            try await WindowFinder.printList()
            exit(0)
        } catch {
            fail("cannot enumerate windows: \(error.localizedDescription)\nGrant Screen Recording to your terminal in System Settings → Privacy & Security, then relaunch.")
        }
    }
    RunLoop.main.run()
}

guard opts.query != nil || opts.pid != nil else {
    print(usageText)
    exit(2)
}

let session = SessionController(opts: opts)
session.start()
RunLoop.main.run()
