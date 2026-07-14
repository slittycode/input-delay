import Foundation
import Darwin

// MARK: - Mach time

enum MachTime {
    private static let tb: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func toNs(_ ticks: UInt64) -> UInt64 {
        ticks * UInt64(tb.numer) / UInt64(tb.denom)
    }

    static func nowNs() -> UInt64 {
        toNs(mach_absolute_time())
    }
}

// MARK: - Percentiles

/// Nearest-rank percentile over an already-sorted array.
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[idx]
}

// MARK: - Stats containers

struct WindowStats {
    var frames = 0
    var fps: Double = 0
    var ftP50: Double = 0
    var ftP95: Double = 0
    var ftMax: Double = 0
    var inputs = 0
    var latP50: Double = 0
    var latP95: Double = 0
}

struct SessionStats {
    var durationS: Double = 0
    var frames = 0
    var avgFps: Double = 0
    var onePercentLowFps: Double = 0
    var ftP50: Double = 0
    var ftP95: Double = 0
    var ftP99: Double = 0
    var ftMax: Double = 0
    var latencies = 0
    var latP50: Double = 0
    var latP95: Double = 0
}

// MARK: - Tracker

enum InputKind {
    case keyboardMouse
    case controller
}

/// Central measurement state. Frames arrive on the capture queue, inputs on the
/// main run loop, stats are drained by the 1 Hz ticker — hence the lock.
final class Tracker {
    private let lock = NSLock()

    private var lastFrameNs: UInt64 = 0
    private var winFrames = 0
    private var winIntervalsMs: [Double] = []
    private var winLatenciesMs: [Double] = []
    private var winInputs = 0

    private var pendingInputs: [(ns: UInt64, kind: InputKind)] = []

    private var sesIntervalsMs: [Double] = []
    private var sesLatenciesMs: [Double] = []
    private(set) var totalFrames = 0

    let startNs = MachTime.nowNs()

    /// An input more than this old when the next frame lands is discarded —
    /// the window wasn't updating in response to anything (paused game, menu idle).
    private let staleInputMs = 5000.0

    /// Fired (outside the lock, on the capture queue) whenever an input resolves
    /// against a presented frame — powers the instant per-press HUD readout.
    var onLatencySample: ((Double, InputKind) -> Void)?

    func recordFrame(displayNs: UInt64) {
        var resolvedLast: (Double, InputKind)?
        lock.lock()
        if lastFrameNs != 0, displayNs > lastFrameNs {
            let ms = Double(displayNs - lastFrameNs) / 1e6
            winIntervalsMs.append(ms)
            sesIntervalsMs.append(ms)
        }
        winFrames += 1
        totalFrames += 1
        if !pendingInputs.isEmpty {
            var remaining: [(ns: UInt64, kind: InputKind)] = []
            for p in pendingInputs {
                if p.ns < displayNs {
                    let ms = Double(displayNs - p.ns) / 1e6
                    if ms <= staleInputMs {
                        winLatenciesMs.append(ms)
                        sesLatenciesMs.append(ms)
                        resolvedLast = (ms, p.kind)
                    }
                } else {
                    remaining.append(p)
                }
            }
            pendingInputs = remaining
        }
        lastFrameNs = displayNs
        lock.unlock()
        if let (ms, kind) = resolvedLast, let cb = onLatencySample {
            cb(ms, kind)
        }
    }

    func recordInput(ns: UInt64, kind: InputKind) {
        lock.lock()
        defer { lock.unlock() }
        winInputs += 1
        pendingInputs.append((ns: ns, kind: kind))
        // A burst of inputs while the window never redraws shouldn't grow unbounded.
        if pendingInputs.count > 64 {
            pendingInputs.removeFirst(pendingInputs.count - 64)
        }
    }

    /// Reset frame continuity after a stream restart so the reattach gap
    /// doesn't register as one giant frametime.
    func markDiscontinuity() {
        lock.lock()
        lastFrameNs = 0
        pendingInputs.removeAll()
        lock.unlock()
    }

    func drainWindow(elapsedS: Double) -> WindowStats {
        lock.lock()
        let intervals = winIntervalsMs.sorted()
        let latencies = winLatenciesMs.sorted()
        var s = WindowStats()
        s.frames = winFrames
        s.inputs = winInputs
        winIntervalsMs.removeAll(keepingCapacity: true)
        winLatenciesMs.removeAll(keepingCapacity: true)
        winFrames = 0
        winInputs = 0
        lock.unlock()

        s.fps = elapsedS > 0 ? Double(s.frames) / elapsedS : 0
        s.ftP50 = percentile(intervals, 0.50)
        s.ftP95 = percentile(intervals, 0.95)
        s.ftMax = intervals.last ?? 0
        s.latP50 = percentile(latencies, 0.50)
        s.latP95 = percentile(latencies, 0.95)
        return s
    }

    func sessionSummary() -> SessionStats {
        lock.lock()
        let intervals = sesIntervalsMs.sorted()
        let latencies = sesLatenciesMs.sorted()
        let frames = totalFrames
        lock.unlock()

        var s = SessionStats()
        s.durationS = Double(MachTime.nowNs() - startNs) / 1e9
        s.frames = frames
        s.avgFps = s.durationS > 0 ? Double(frames) / s.durationS : 0
        let p99ft = percentile(intervals, 0.99)
        s.onePercentLowFps = p99ft > 0 ? 1000.0 / p99ft : 0
        s.ftP50 = percentile(intervals, 0.50)
        s.ftP95 = percentile(intervals, 0.95)
        s.ftP99 = p99ft
        s.ftMax = intervals.last ?? 0
        s.latencies = latencies.count
        s.latP50 = percentile(latencies, 0.50)
        s.latP95 = percentile(latencies, 0.95)
        return s
    }
}

// MARK: - Process cost (1 Hz rusage sampling)

struct ProcSample {
    var cpuPercent: Double
    var footprintGB: Double
}

final class ProcMonitor {
    let pid: pid_t
    private var lastCpuNs: UInt64 = 0
    private var lastSampleNs: UInt64 = 0

    init(pid: pid_t) {
        self.pid = pid
    }

    func sample() -> ProcSample? {
        var info = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard ret == 0 else { return nil }
        // ri_*_time are mach ticks.
        let cpuNs = MachTime.toNs(info.ri_user_time + info.ri_system_time)
        let now = MachTime.nowNs()
        defer {
            lastCpuNs = cpuNs
            lastSampleNs = now
        }
        let footprint = Double(info.ri_phys_footprint) / 1e9
        guard lastSampleNs != 0, now > lastSampleNs, cpuNs >= lastCpuNs else {
            return ProcSample(cpuPercent: 0, footprintGB: footprint)
        }
        let pct = Double(cpuNs - lastCpuNs) / Double(now - lastSampleNs) * 100.0
        return ProcSample(cpuPercent: pct, footprintGB: footprint)
    }
}

// MARK: - CSV

final class CSVWriter {
    let path: String
    private let handle: FileHandle

    init?(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { return nil }
        self.path = path
        self.handle = h
        write("time,fps,ft_p50_ms,ft_p95_ms,ft_max_ms,inputs,in2present_p50_ms,in2present_p95_ms,cpu_pct,mem_gb\n")
    }

    func append(_ w: WindowStats, proc: ProcSample?) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = String(
            format: "%@,%.1f,%.2f,%.2f,%.2f,%d,%.1f,%.1f,%.0f,%.2f\n",
            ts, w.fps, w.ftP50, w.ftP95, w.ftMax, w.inputs, w.latP50, w.latP95,
            proc?.cpuPercent ?? 0, proc?.footprintGB ?? 0
        )
        write(line)
    }

    func close() {
        try? handle.close()
    }

    private func write(_ s: String) {
        if let d = s.data(using: .utf8) {
            try? handle.write(contentsOf: d)
        }
    }
}
