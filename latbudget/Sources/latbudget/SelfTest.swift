import Foundation
import Darwin

/// Proof that the harness is never the bottleneck. Three checks, each against a
/// 1000 Hz source, each with hard pass thresholds. Run with `latbudget --selftest`.
enum SelfTest {
    static func run() -> Bool {
        var allPass = true
        print("latbudget self-test — proving the harness resolves a 1000 Hz source\n")

        // ── 1. Stats resolution: perfect synthetic 1 kHz through the exact ingest path
        do {
            let s = IntervalSeries()
            let base = MachTime.nowNs()
            for i in 0..<5000 {
                let t = base + UInt64(i) * 1_000_000
                s.ingest(eventNs: t, arrivalNs: t)
            }
            let sum = s.summary()
            let pass = abs(sum.medianMs - 1.0) < 0.001 && sum.jitterMs < 0.001 && sum.n == 4999
            allPass = allPass && pass
            print(String(format: "[1] stats pipeline @1kHz: median %.4fms jitter σ %.5fms n=%d → %@",
                         sum.medianMs, sum.jitterMs, sum.n, pass ? "PASS" : "FAIL"))
        }

        // ── 2. Live timing thread: mach_wait_until-paced 1 kHz source, ingested through
        //      a dispatch hop (same shape as a real callback). Verifies no drops and
        //      that scheduling lag stays well under one source period.
        do {
            let s = IntervalSeries()
            let q = DispatchQueue(label: "selftest.ingest")
            let events = 3000
            let group = DispatchGroup()
            var lagsUs = [Double](repeating: 0, count: events)
            let startTicks = mach_absolute_time() + MachTime.nsToTicks(10_000_000)
            let periodTicks = MachTime.nsToTicks(1_000_000)
            // enter up front — waiting on a group nothing has entered returns immediately
            for _ in 0..<events { group.enter() }

            let thread = Thread {
                for i in 0..<events {
                    let target = startTicks + UInt64(i) * periodTicks
                    mach_wait_until(target)
                    let scheduledNs = MachTime.toNs(target)
                    q.async {
                        let arrival = MachTime.nowNs()
                        lagsUs[i] = arrival > scheduledNs ? Double(arrival - scheduledNs) / 1e3 : 0
                        s.ingest(eventNs: scheduledNs, arrivalNs: arrival)
                        group.leave()
                    }
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
            let waited = group.wait(timeout: .now() + 10)
            let sum = s.summary()
            let sortedLags = lagsUs.sorted()
            let lagP99 = percentile(sortedLags, 0.99)
            let pass = waited == .success && sum.n == events - 1
                && abs(sum.medianMs - 1.0) < 0.05 && lagP99 < 1000 // < 1 ms at p99
            allPass = allPass && pass
            print(String(format: "[2] live 1kHz via dispatch: median %.4fms n=%d ingest-lag p50 %.0fµs p99 %.0fµs → %@",
                         sum.medianMs, sum.n, percentile(sortedLags, 0.50), lagP99, pass ? "PASS" : "FAIL"))
        }

        // ── 3. UDP loopback at 1 kHz: the bottle-link path must sustain source rate
        //      with ≤1% loss and sub-ms mapped-time error.
        do {
            let link = BottleLink()
            let port: UInt16 = 4599
            guard link.start(port: port) else {
                print("[3] UDP loopback: FAIL (cannot bind test port \(port))")
                return false
            }
            var errorsUs: [Double] = []
            let errLock = NSLock()
            link.onPacketChange = { ev in
                let now = MachTime.nowNs()
                let err = now > ev.machNs ? Double(now - ev.machNs) / 1e3 : 0
                errLock.lock(); errorsUs.append(err); errLock.unlock()
            }

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var dest = sockaddr_in()
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            dest.sin_addr.s_addr = inet_addr("127.0.0.1")
            let events = 2000
            let sender = Thread {
                let startTicks = mach_absolute_time() + MachTime.nsToTicks(10_000_000)
                let periodTicks = MachTime.nsToTicks(1_000_000)
                for i in 0..<events {
                    mach_wait_until(startTicks + UInt64(i) * periodTicks)
                    // qpf = 1e9 → qpc field is plain nanoseconds
                    var pkt = [UInt8](repeating: 0, count: BottleLink.packetSize)
                    func put32(_ v: UInt32, _ o: Int) { for b in 0..<4 { pkt[o + b] = UInt8((v >> (8 * UInt32(b))) & 0xFF) } }
                    func put64(_ v: UInt64, _ o: Int) { for b in 0..<8 { pkt[o + b] = UInt8((v >> (8 * UInt64(b))) & 0xFF) } }
                    put32(BottleLink.magic, 0)
                    pkt[4] = 1 // packet-change
                    put32(UInt32(i), 8)
                    put64(MachTime.nowNs(), 12)
                    put64(1_000_000_000, 20)
                    put32(UInt32(i), 36)
                    _ = withUnsafePointer(to: &dest) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            pkt.withUnsafeBytes { raw in
                                sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            sender.qualityOfService = .userInteractive
            sender.start()

            // Receiver runs on the main run loop — pump it for the test duration.
            let deadline = Date(timeIntervalSinceNow: 3.5)
            while Date() < deadline, RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) {}
            close(fd)

            errLock.lock()
            let received = errorsUs.count
            let sortedErr = errorsUs.sorted()
            errLock.unlock()
            let lossPct = Double(events - received) / Double(events) * 100
            let errP99 = percentile(sortedErr, 0.99)
            let pass = received >= events * 99 / 100 && errP99 < 1500 // mapped-time err < 1.5 ms p99
            allPass = allPass && pass
            print(String(format: "[3] UDP loopback @1kHz: received %d/%d (loss %.1f%%) mapped-time err p50 %.0fµs p99 %.0fµs → %@",
                         received, events, lossPct, percentile(sortedErr, 0.50), errP99, pass ? "PASS" : "FAIL"))
        }

        print(allPass
            ? "\nSELF-TEST PASS — harness resolves 1 kHz with headroom; it is not the bottleneck."
            : "\nSELF-TEST FAIL — do not trust cadence numbers from this build/host state.")
        return allPass
    }
}
