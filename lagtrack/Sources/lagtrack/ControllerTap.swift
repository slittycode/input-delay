import Foundation
import IOKit.hid

/// Raw-HID controller listener. Empirically proven (gcprobe/hidmon, 2026-07-15) to
/// receive gamepad input reports in the BACKGROUND once Input Monitoring is granted —
/// the earlier "zero reports" finding was a permission artifact, not a driver seize.
///
/// Counts discrete inputs only: button presses (usage page 0x09, transition to
/// pressed) and d-pad/hat changes (usage 0x39, leaving center). Analog axes are
/// ignored — stick jitter must not pollute the latency samples. Timestamps come from
/// the kernel report (IOHIDValueGetTimeStamp), not callback delivery.
final class ControllerTap {
    typealias Handler = (UInt64) -> Void // event time, ns on the mach clock

    private var mgr: IOHIDManager?
    fileprivate let handler: Handler
    fileprivate let shouldRecord: () -> Bool
    fileprivate var lastHatValue: CFIndex = -1

    init?(handler: @escaping Handler, shouldRecord: @escaping () -> Bool) {
        self.handler = handler
        self.shouldRecord = shouldRecord

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x05], // GamePad
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x04], // Joystick
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        IOHIDManagerRegisterInputValueCallback(mgr, controllerValueCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return nil
        }
        self.mgr = mgr
    }
}

private func controllerValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let tap = Unmanaged<ControllerTap>.fromOpaque(context).takeUnretainedValue()

    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    let isPress: Bool
    if page == 0x09 {
        // Button page: count the press edge only.
        isPress = intValue != 0
    } else if page == 0x01, usage == 0x39 {
        // Hat switch (d-pad): count movement away from center as a press.
        let wasCentered = tap.lastHatValue < IOHIDElementGetLogicalMin(element)
            || tap.lastHatValue > IOHIDElementGetLogicalMax(element)
            || tap.lastHatValue == -1
        let isCentered = intValue < IOHIDElementGetLogicalMin(element)
            || intValue > IOHIDElementGetLogicalMax(element)
        isPress = !isCentered && (wasCentered || tap.lastHatValue != intValue)
        tap.lastHatValue = intValue
    } else {
        return // analog axes / triggers: ignored, jitter isn't input
    }

    guard isPress, tap.shouldRecord() else { return }
    tap.handler(MachTime.toNs(IOHIDValueGetTimeStamp(value)))
}
