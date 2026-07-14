import Foundation
import IOKit.hid

/// STAGE 1 — host-side HID. Raw input REPORTS (not per-element values) per device,
/// timestamped by the kernel (`IOHIDDeviceRegisterInputReportWithTimeStampCallback`),
/// never by wall-clock-on-arrival. Delivery lag (report ts → callback) is tracked
/// separately so harness overhead is visible, not silently folded into cadence.
final class HIDStage {
    final class Device {
        let name: String
        let series = IntervalSeries()
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferSize: Int

        init(name: String, bufferSize: Int) {
            self.name = name
            self.bufferSize = max(8, bufferSize)
            self.buffer = .allocate(capacity: self.bufferSize)
        }

        deinit { buffer.deallocate() }
    }

    private let lock = NSLock()
    private var devices: [UInt: Device] = [:]
    private var mgr: IOHIDManager?

    /// Every gamepad report's kernel timestamp (ns) — feeds stage-C correlation.
    var onReport: ((UInt64) -> Void)?

    func start() -> Bool {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x05], // GamePad
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x04], // Joystick
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, hidStageDeviceMatched,
                                                   Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return false
        }
        self.mgr = mgr
        return true
    }

    fileprivate func matched(device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "unknown device"
        let maxReport = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
        let dev = Device(name: name, bufferSize: maxReport)
        let key = UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        lock.lock()
        devices[key] = dev
        lock.unlock()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device, dev.buffer, dev.bufferSize, hidStageReport,
            Unmanaged.passUnretained(self).toOpaque()
        )
        print("latbudget: [B] device attached: \(name) (max report \(maxReport) B)")
    }

    fileprivate func report(senderKey: UInt, timeStampTicks: UInt64) {
        let eventNs = MachTime.toNs(timeStampTicks)
        let arrivalNs = MachTime.nowNs()
        lock.lock()
        let dev = devices[senderKey]
        lock.unlock()
        dev?.series.ingest(eventNs: eventNs, arrivalNs: arrivalNs)
        onReport?(eventNs)
    }

    func summaries() -> [(name: String, summary: SeriesSummary)] {
        lock.lock()
        let devs = Array(devices.values)
        lock.unlock()
        return devs.map { ($0.name, $0.series.summary()) }
    }
}

private func hidStageDeviceMatched(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<HIDStage>.fromOpaque(context).takeUnretainedValue().matched(device: device)
}

private func hidStageReport(
    context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType, reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex, timeStamp: UInt64
) {
    guard let context, let sender else { return }
    Unmanaged<HIDStage>.fromOpaque(context).takeUnretainedValue()
        .report(senderKey: UInt(bitPattern: sender), timeStampTicks: timeStamp)
}
