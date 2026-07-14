// gcprobe — empirical test: does GCController deliver events to a NON-frontmost app
// when GCController.shouldMonitorBackgroundEvents = true?
//
// Prior sessions proved SDL/pygame/raw-HID get nothing in the background, but a native
// GameController client with this flag was never tested. If this works, lagtrack can
// timestamp controller input live and pair it with presented frames.
//
// Build: xcrun swiftc -O gcprobe.swift -o gcprobe
// Run:   ./gcprobe            then focus ANOTHER window and press buttons / move sticks.
// Exits ~60 s after the first controller event (or after 10 min with no controller).

import AppKit
import GameController

setvbuf(stdout, nil, _IONBF, 0) // unbuffered so logs are readable while running
_ = NSApplication.shared
GCController.shouldMonitorBackgroundEvents = true

var totalEvents = 0
var backgroundEvents = 0
var frontmostEvents = 0
var firstEventNs: UInt64 = 0
var printed = 0

func nowNs() -> UInt64 {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return mach_absolute_time() * UInt64(tb.numer) / UInt64(tb.denom)
}

func summarizeAndExit() {
    print("""

    ── gcprobe result ──────────────────────────────
    total events        \(totalEvents)
    while BACKGROUND    \(backgroundEvents)
    while frontmost     \(frontmostEvents)
    verdict: \(backgroundEvents > 0
        ? "BACKGROUND CONTROLLER EVENTS WORK — lagtrack can observe the pad live"
        : (totalEvents > 0 ? "events only while frontmost — background path dead"
                           : "no events at all — pad never spoke"))
    ────────────────────────────────────────────────
    """)
    exit(0)
}

func attach(_ pad: GCController) {
    print("gcprobe: controller connected: \(pad.vendorName ?? "?")")
    print("gcprobe: NOW FOCUS ANOTHER WINDOW and press buttons / move the sticks.")
    pad.extendedGamepad?.valueChangedHandler = { _, element in
        totalEvents += 1
        if firstEventNs == 0 { firstEventNs = nowNs() }
        let front = NSWorkspace.shared.frontmostApplication
        let isMe = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if isMe { frontmostEvents += 1 } else { backgroundEvents += 1 }
        if printed < 15 || totalEvents % 100 == 0 {
            printed += 1
            let where_ = isMe ? "FRONTMOST(me)" : "BACKGROUND (front: \(front?.localizedName ?? "?"))"
            print("gcprobe: #\(totalEvents) \(element) — \(where_)")
        }
        if nowNs() - firstEventNs > 60_000_000_000 { summarizeAndExit() }
    }
}

NotificationCenter.default.addObserver(
    forName: .GCControllerDidConnect, object: nil, queue: .main
) { note in
    if let pad = note.object as? GCController { attach(pad) }
}
for pad in GCController.controllers() { attach(pad) }

let waitS = Double(CommandLine.arguments.dropFirst().first ?? "") ?? 3600
if GCController.controllers().isEmpty {
    print("gcprobe: no controller yet — plug in / wake the pad (probe waits up to \(Int(waitS / 60)) min)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + waitS) { summarizeAndExit() }
RunLoop.main.run()
