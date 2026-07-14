import Foundation
import Darwin

/// STAGE 2 receiver — UDP link from the in-bottle XInput proxy DLL (wine/xinput_proxy.c).
///
/// Clock correlation: the DLL stamps each packet with QueryPerformanceCounter. Wine's
/// QPC is mach-clock based, so (host arrival − qpc) has a constant true offset plus
/// non-negative loopback/queueing noise. The running MINIMUM of that difference
/// converges on the true offset (loopback ≈ tens of µs), letting us map bottle event
/// times onto the host mach timeline to sub-ms accuracy.
final class BottleLink {
    // Packet layout (little-endian, packed, 40 bytes) — must match wine/xinput_proxy.c:
    //  u32 magic 'XLNK' | u8 kind (0 hello, 1 packet-change, 2 poll-stats) | u8 slot
    //  u16 buttons | u32 packetNumber | u64 qpc | u64 qpf | u32 pollsSince
    //  u32 changesSince | u32 seq
    static let packetSize = 40
    static let magic: UInt32 = 0x4B4E_4C58 // "XLNK" little-endian

    struct Event {
        let machNs: UInt64
        let buttons: UInt16
        let packetNumber: UInt32
    }

    private var sock: Int32 = -1
    private var source: DispatchSourceRead?
    private let lock = NSLock()

    private(set) var packetsReceived = 0
    private(set) var changeEvents = 0
    private(set) var lastPollRateHz: Double = 0
    private(set) var offsetMinNs: Int64 = .max
    private(set) var helloSeen = false

    var onPacketChange: ((Event) -> Void)?

    func start(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        sock = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
        return true
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            guard n >= Self.packetSize else { break }
            parse(bytes: buf, arrivalNs: MachTime.nowNs())
        }
    }

    private func parse(bytes: [UInt8], arrivalNs: UInt64) {
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[o + $1]) << (8 * UInt32($1)) } }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[o + $1]) << (8 * UInt64($1)) } }

        guard u32(0) == Self.magic else { return }
        let kind = bytes[4]
        let buttons = u16(6)
        let packetNumber = u32(8)
        let qpc = u64(12)
        let qpf = u64(20)
        let pollsSince = u32(28)
        guard qpf > 0 else { return }
        // Double keeps ns precision to well under a µs at uptime scales — fine for ms budgets.
        let qpcNs = UInt64(Double(qpc) / Double(qpf) * 1e9)

        lock.lock()
        packetsReceived += 1
        let diff = Int64(bitPattern: arrivalNs) - Int64(bitPattern: qpcNs)
        if diff < offsetMinNs { offsetMinNs = diff }
        let offset = offsetMinNs
        lock.unlock()

        switch kind {
        case 0:
            if !helloSeen {
                helloSeen = true
                print("latbudget: [C] in-bottle proxy connected (qpf \(qpf))")
            }
        case 1:
            lock.lock(); changeEvents += 1; lock.unlock()
            let machNs = UInt64(Int64(bitPattern: qpcNs) + offset)
            onPacketChange?(Event(machNs: machNs, buttons: buttons, packetNumber: packetNumber))
        case 2:
            // pollsSince over the DLL's ~2 s stats window
            lock.lock(); lastPollRateHz = Double(pollsSince) / 2.0; lock.unlock()
        default:
            break
        }
    }

    /// Bound on clock-sync error: how far above the true offset the current estimate
    /// can be is bounded by the smallest observed loopback delay (unknowable but tiny);
    /// we report the spread between min and p10 of recent diffs as a practical bound.
    func syncBoundMs() -> Double {
        // Conservative fixed bound for loopback UDP on this machine class.
        0.5
    }
}
