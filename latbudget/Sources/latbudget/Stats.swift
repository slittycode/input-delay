import Foundation
import Darwin

// MARK: - Monotonic time (mach_absolute_time only — no datetime, no wall clock)

enum MachTime {
    private static let tb: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func toNs(_ ticks: UInt64) -> UInt64 { ticks * UInt64(tb.numer) / UInt64(tb.denom) }
    static func nsToTicks(_ ns: UInt64) -> UInt64 { ns * UInt64(tb.denom) / UInt64(tb.numer) }
    static func nowNs() -> UInt64 { toNs(mach_absolute_time()) }
}

// MARK: - Descriptive stats

/// Nearest-rank percentile over an already-sorted array.
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, Int(Double(sorted.count) * p))
    return sorted[idx]
}

func stddev(_ xs: [Double]) -> Double {
    guard xs.count > 1 else { return 0 }
    let mean = xs.reduce(0, +) / Double(xs.count)
    let varSum = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    return (varSum / Double(xs.count - 1)).squareRoot()
}

struct SeriesSummary {
    var n = 0
    var medianMs: Double = 0
    var p99Ms: Double = 0
    var jitterMs: Double = 0 // stddev — the headline number for cadence quality
    var maxMs: Double = 0
    var reports = 0
    var idleGaps = 0
    var lagP50Us: Double = 0 // event timestamp → in-process arrival (harness overhead)
    var lagP99Us: Double = 0
}

// MARK: - Interval series with idle-gap awareness

/// A still stick sends no reports: any interval above `gapMs` is an idle gap and is
/// counted separately, never mixed into the cadence statistics.
final class IntervalSeries {
    let gapMs: Double
    private let lock = NSLock()
    private var intervalsMs: [Double] = []
    private var deliveryLagUs: [Double] = []
    private var reports = 0
    private var idleGaps = 0
    private var lastNs: UInt64 = 0

    init(gapMs: Double = 200) {
        self.gapMs = gapMs
    }

    /// eventNs: the report's OWN kernel timestamp. arrivalNs: when this process saw it.
    func ingest(eventNs: UInt64, arrivalNs: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        reports += 1
        deliveryLagUs.append(arrivalNs > eventNs ? Double(arrivalNs - eventNs) / 1e3 : 0)
        if lastNs != 0, eventNs > lastNs {
            let ms = Double(eventNs - lastNs) / 1e6
            if ms <= gapMs {
                intervalsMs.append(ms)
            } else {
                idleGaps += 1
            }
        }
        lastNs = eventNs
        if intervalsMs.count > 200_000 { intervalsMs.removeFirst(100_000) }
        if deliveryLagUs.count > 200_000 { deliveryLagUs.removeFirst(100_000) }
    }

    func summary() -> SeriesSummary {
        lock.lock()
        let iv = intervalsMs.sorted()
        let lag = deliveryLagUs.sorted()
        var s = SeriesSummary()
        s.reports = reports
        s.idleGaps = idleGaps
        lock.unlock()
        s.n = iv.count
        s.medianMs = percentile(iv, 0.50)
        s.p99Ms = percentile(iv, 0.99)
        s.jitterMs = stddev(iv)
        s.maxMs = iv.last ?? 0
        s.lagP50Us = percentile(lag, 0.50)
        s.lagP99Us = percentile(lag, 0.99)
        return s
    }
}
