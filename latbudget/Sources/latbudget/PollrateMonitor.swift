import Foundation
import IOKit.hid

final class PollrateMonitor {
    private struct Controller {
        let name: String
        let transport: String
        var reports = 0
        var intervalsMs: [Double] = []
        var lastTsTicks: UInt64 = 0
    }

    private let lock = NSLock()
    private var mgr: IOHIDManager?
    private var controllers: [UInt: Controller] = [:]
    let startNs = MachTime.nowNs()

    struct Snapshot {
        let deviceName: String
        let transport: String
        let deviceCount: Int
        let reports: Int
        let intervals: Int
        let liveRateHz: Double
        let pollingRateHz: Double
        let medianMs: Double
        let avgMs: Double
        let jitterMs: Double
        let minMs: Double
        let maxMs: Double
        let elapsedS: Double
    }

    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x05],
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x04],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(
            mgr, pollrateDeviceMatched,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerRegisterInputValueCallback(
            mgr, pollrateValueCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }
        self.mgr = mgr
        return true
    }

    fileprivate func matched(device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "gamepad"
        let tport = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? "?"
        let key = deviceKey(device)
        lock.lock()
        if controllers[key] != nil { lock.unlock(); return }
        controllers[key] = Controller(name: name, transport: tport)
        let count = controllers.count
        lock.unlock()
        FileHandle.standardError.write(Data("latbudget: device attached: \(name) (\(tport)) [\(count) total]\n".utf8))
    }

    fileprivate func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        let key = deviceKey(device)
        let ticks = IOHIDValueGetTimeStamp(value)
        lock.lock()
        guard var ctrl = controllers[key] else { lock.unlock(); return }
        if ticks != ctrl.lastTsTicks {
            ctrl.reports += 1
            if ctrl.lastTsTicks != 0, ticks > ctrl.lastTsTicks {
                let ms = Double(MachTime.toNs(ticks) - MachTime.toNs(ctrl.lastTsTicks)) / 1e6
                if ms <= 200 { ctrl.intervalsMs.append(ms) }
            }
            ctrl.lastTsTicks = ticks
        }
        controllers[key] = ctrl
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let all = controllers.values.sorted(by: { $0.reports > $1.reports })
        lock.unlock()
        guard let primary = all.first else {
            return Snapshot(deviceName: "no controller", transport: "?", deviceCount: 0,
                            reports: 0, intervals: 0, liveRateHz: 0, pollingRateHz: 0, medianMs: 0,
                            avgMs: 0, jitterMs: 0, minMs: 0, maxMs: 0,
                            elapsedS: Double(MachTime.nowNs() - startNs) / 1e9)
        }
        let sorted = primary.intervalsMs.sorted()
        let med = percentile(sorted, 0.50)
        let avg = primary.intervalsMs.isEmpty ? 0.0 : primary.intervalsMs.reduce(0, +) / Double(primary.intervalsMs.count)
        let elapsed = Double(MachTime.nowNs() - startNs) / 1e9
        let recent = primary.intervalsMs.suffix(64)
        let recentMed = percentile(recent.sorted(), 0.50)
        let liveRate = recentMed > 0 ? 1000.0 / recentMed : 0
        return Snapshot(
            deviceName: primary.name,
            transport: primary.transport,
            deviceCount: all.count,
            reports: primary.reports,
            intervals: primary.intervalsMs.count,
            liveRateHz: liveRate,
            pollingRateHz: med > 0 ? 1000.0 / med : 0,
            medianMs: med,
            avgMs: avg,
            jitterMs: stddev(primary.intervalsMs),
            minMs: sorted.first ?? 0,
            maxMs: sorted.last ?? 0,
            elapsedS: elapsed
        )
    }

    func collectReports() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return controllers.values.reduce(0) { $0 + $1.reports }
    }
}

private func deviceKey(_ device: IOHIDDevice) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
}

private func pollrateDeviceMatched(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<PollrateMonitor>.fromOpaque(context).takeUnretainedValue().matched(device: device)
}

private func pollrateValueCallback(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, value: IOHIDValue
) {
    guard let context else { return }
    Unmanaged<PollrateMonitor>.fromOpaque(context).takeUnretainedValue().handleValue(value)
}
