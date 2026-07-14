// hidmon — retest of raw IOHID input reports from a context that HAS Input Monitoring.
//
// The original hidprobe.c run got "OPEN_OK + zero reports" and the write-up attributed
// it to XboxGamepad.dext seizing the device — but its own comments flagged the other
// suspect: Input Monitoring permission. This process context is proven to have Input
// Monitoring (lagtrack's CGEventTap works here), so a zero here is a real seize,
// and reports here mean the old conclusion was a permission artifact.
//
// Build: xcrun swiftc -O hidmon.swift -o hidmon
// Run:   ./hidmon      connect pad, focus another window, press buttons / move sticks.
// Exits ~60 s after the first report (or after 10 min without one).

import AppKit
import IOKit.hid

setvbuf(stdout, nil, _IONBF, 0) // unbuffered so logs are readable while running
_ = NSApplication.shared

var totalReports = 0
var backgroundReports = 0
var firstNs: UInt64 = 0

func nowNs() -> UInt64 {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return mach_absolute_time() * UInt64(tb.numer) / UInt64(tb.denom)
}

func summarizeAndExit() {
    print("""

    ── hidmon result ───────────────────────────────
    total raw-HID input reports  \(totalReports)
    while BACKGROUND             \(backgroundReports)
    verdict: \(totalReports > 0
        ? "RAW HID DELIVERS — old zero-reports result was a permission artifact"
        : "still zero with Input Monitoring granted — the dext seize is real")
    ────────────────────────────────────────────────
    """)
    exit(0)
}

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matches: [[String: Int]] = [
    [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x05], // GamePad
    [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x04], // Joystick
]
IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)

IOHIDManagerRegisterDeviceMatchingCallback(mgr, { _, _, _, dev in
    let name = (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "?"
    print("hidmon: matched device: \(name)")
    print("hidmon: NOW FOCUS ANOTHER WINDOW and press buttons / move the sticks.")
}, nil)

IOHIDManagerRegisterInputValueCallback(mgr, { _, _, _, value in
    totalReports += 1
    if firstNs == 0 { firstNs = nowNs() }
    let front = NSWorkspace.shared.frontmostApplication
    let isMe = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    if !isMe { backgroundReports += 1 }
    if totalReports <= 15 || totalReports % 200 == 0 {
        let el = IOHIDValueGetElement(value)
        print("hidmon: #\(totalReports) page=0x\(String(IOHIDElementGetUsagePage(el), radix: 16))"
            + " usage=0x\(String(IOHIDElementGetUsage(el), radix: 16))"
            + " val=\(IOHIDValueGetIntegerValue(value))"
            + " — \(isMe ? "FRONTMOST(me)" : "BACKGROUND")")
    }
    if nowNs() - firstNs > 60_000_000_000 { summarizeAndExit() }
}, nil)

IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
print("hidmon: IOHIDManagerOpen -> \(r == kIOReturnSuccess ? "OPEN_OK" : String(format: "FAILED 0x%08x", r))")
let waitS = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 3600
print("hidmon: waiting for gamepad reports (up to \(Int(waitS / 60)) min)…")

DispatchQueue.main.asyncAfter(deadline: .now() + waitS) { summarizeAndExit() }
RunLoop.main.run()
