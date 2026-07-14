import Foundation
import CoreGraphics

/// Listen-only CGEventTap for discrete inputs (key down, mouse buttons).
/// Deliberately excludes mouse-moved / scroll — high-rate noise, useless for
/// pairing with individual frames. Requires Input Monitoring permission.
final class InputTap {
    typealias Handler = (UInt64) -> Void // event time, ns on the mach clock

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler
    private let shouldRecord: () -> Bool

    init?(handler: @escaping Handler, shouldRecord: @escaping () -> Bool) {
        self.handler = handler
        self.shouldRecord = shouldRecord

        var mask: CGEventMask = 0
        for t: CGEventType in [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return
        }
        guard shouldRecord() else { return }
        handler(Self.eventNs(event))
    }

    /// CGEventTimestamp is documented as nanoseconds but has shipped as raw mach
    /// ticks on some hardware. Pick whichever interpretation lands near "now";
    /// fall back to "now" (the callback fires well under a frame after the event).
    private static func eventNs(_ event: CGEvent) -> UInt64 {
        let raw = event.timestamp
        let nowNs = MachTime.nowNs()
        let asTicks = MachTime.toNs(raw)
        func dist(_ a: UInt64, _ b: UInt64) -> UInt64 { a > b ? a - b : b - a }
        let plausible: UInt64 = 5_000_000_000
        let dTicks = dist(asTicks, nowNs)
        let dRaw = dist(raw, nowNs)
        if dTicks <= dRaw, dTicks < plausible { return asTicks }
        if dRaw < plausible { return raw }
        return nowNs
    }
}

private func inputTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let tap = Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue()
        tap.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
