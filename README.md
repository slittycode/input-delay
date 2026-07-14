# Controller Input-Latency Measurement (macOS, Apple Silicon)

An empirical environment for measuring game-controller performance on macOS. It separates two
things that are often conflated, measures each with a real tool, and documents the
Mac-specific traps that make naive measurements wrong.

> **Ground rule of this project:** no latency number is invented. Every figure comes from an
> actual run, and where a clean measurement isn't obtainable we say so instead of guessing.
> The running log of what was tried (including dead ends) is in [NOTES.md](NOTES.md).

## The two categories of measurement (and why they differ)

| | **Category 1 — Polling / report interval** | **Category 2 — Button-to-photon** |
|---|---|---|
| What it measures | How often the controller reports state (Hz) and how evenly (jitter) | Time from a physical press to the screen reacting |
| Typical scale | ~5–15 ms between reports (≈65–1000 Hz) | ~30–120+ ms end to end |
| Includes | Only the controller→OS report cadence | Controller report **+** USB/BT **+** OS **+** game **+** render **+** display response |
| Tool here | gamepadla-plus / browser Gamepad API / in-bottle XInput probe | inputLagTimer + high-speed video |
| Needs | Just the controller | A phone that shoots 240 fps slow-mo |

They are not the same quantity and one does not convert to the other. A 1000 Hz controller
still has 40+ ms of button-to-photon latency, because polling is a small slice of the whole
chain. **Category 1 tells you if the controller/transport is a bottleneck; Category 2 tells
you what you actually feel.**

## What's in here

```
lagtrack/              LIVE tracker (Swift): FPS/frametimes/1% low + KB/M + controller
                       input→present proxy + game-process CPU/RAM, via ScreenCaptureKit.
                       External only — works with any CrossOver renderer. lagtrack/README.md.
latbudget/             Per-stage latency BUDGET monitor: host HID cadence (kernel report
                       timestamps) + in-bottle XInput proxy DLL (UDP + clock sync) +
                       present stage. Never prints one number; unmeasured gaps stated.
                       1 kHz self-test. Pipeline verified; NO real-game budget captured
                       yet ([C]/[D] have no play-session samples). latbudget/README.md.
gamepadla-plus/        Category-1 tool (Python/pygame). Enumerates + synthetic polling test.
webtester/gamepad.html Category-1, the path that WORKS on this Mac: browser Gamepad API.
native-results/        Real Category-1 captures (Bluetooth / USB-C / USB-A).
cross-over/            CrossOver in-bottle probes (hidprobe.c, probe_live_gui.c, run-gui-probe.sh).
comparison-table.md    Native vs CrossOver in-bottle results + honest caveats.
inputLagTimer/         Category-2 tool (opencv). Patched to write per-clip result.json.
stage2-workflow.md     How to record + analyze button-to-photon clips.
stage2_measure.sh      Runs inputLagTimer over multiple clips, then aggregates.
stage2_aggregate.py    Pools clips -> median + spread.
log-analyzer/          CrossOver/Wine log scanner (analyze.py, WINEDEBUG reference).
logs-findings.md       What the CrossOver logs can and cannot tell us.
NOTES.md               Chronological log of everything tried, incl. failures + root causes.
```

## Key finding first: how controller input actually works on this Mac

`XboxGamepad.dext` claims the pad's raw USB/BT interface at the IOKit level, wired or
wireless, and re-exposes it through exactly **two doors with two different rules**. Earlier
write-ups here conflated them; corrected 2026-07-15, every claim below from a real run
(see [NOTES.md](NOTES.md)):

1. **GameController-framework path** (browsers, SDL/pygame's MFi backend, native
   `GCController` clients, Wine's input feed). Delivery is **frontmost-only by default**.
   Proven: browser frontmost → ~110 Hz; SDL/pygame from a terminal → enumerates, **0
   events**; windowless Wine probe → 0 packets, windowed+focused → full input. Apple ships
   one exception: a native client that sets
   `GCController.shouldMonitorBackgroundEvents = true` received **37/37 stick events while
   backgrounded** (`gcprobe/`).
2. **Raw `IOHIDManager` path**. **Not frontmost-limited at all** — it is gated by the
   **Input Monitoring permission** (TCC). The early "opens the device, zero reports" result
   came from a process *without* that permission; re-run 2026-07-15 with it granted, a
   backgrounded IOHIDManager client received **110/110 reports** (`gcprobe/hidmon.swift`).
   lagtrack's live controller tap is built on this.

So "the tool sees no input" has two different cures, and you must know which path the tool
uses: GameController-path tools need to be **frontmost** (or set the background-events
flag); raw-HID tools need **Input Monitoring granted**.

## Reproduce Category 1 — polling / report interval

**The reliable native path (browser Gamepad API):**
1. Serve the page: `cd webtester && python3 -m http.server 8777`
2. Open `http://localhost:8777/gamepad.html` in Chrome or Safari.
3. Press any controller button to expose the pad, click **Start**, rotate the left stick in
   continuous circles ~15 s, click **Stop**.
4. Read `polling_rate_hz`. Trust it if `sampler_loop_hz` ≫ `polling_rate_hz` (not loop-capped)
   and the median interval exceeds your display frame time (not refresh-capped).

Measured on this Mac (Xbox Series X/S), from [native-results/](native-results/):

| Connection | Polling rate | Median interval | Jitter (std) |
|---|---|---|---|
| Bluetooth | **67.6 Hz** | 14.8 ms | 7.98 ms |
| USB-C | **109.9 Hz** | 9.1 ms | 5.94 ms |
| USB-A | **108.7 Hz** | 9.2 ms | 4.13 ms |

**Takeaway: use USB, not Bluetooth** — Bluetooth roughly halves the report rate (68 vs 109 Hz)
and raises jitter. USB-C and USB-A are equivalent.

**gamepadla-plus** (also Category 1) builds and enumerates here (`uv run gamepadla list`) but
its live test reads the pad through SDL's GameController (MFi) backend — **mechanism 1
above, frontmost-only** — and a terminal process is never frontmost, so it gets zero events.
This is *not* the raw-HID permission issue. (SDL's hidapi backend was also tried and could
not open the dext-claimed device; whether Input Monitoring changes that is untested.) The
browser tester is the working substitute on this Mac. Details in [NOTES.md](NOTES.md).

**CrossOver in-bottle** (Category 1, "what the game sees through Wine"): run
`cross-over/run-gui-probe.sh` from a real terminal, focus the window, rotate the stick.
Result: **172 Hz live** — CrossOver adds no polling-rate penalty.

Why 172 > 109 when Wine cannot manufacture reports the hardware never sent: the two
counters bracket the truth from opposite sides. The native 109 is **Chromium-capped** (an
*undercount* of the true USB report rate), while `dwPacketNumber` increments on every
XInput state transition winebus applies, which need not be 1:1 with hardware reports (one
HID report can land as more than one state update — an *overcount* relative to raw
reports). Neither number is the raw hardware rate, which is why they measure different
things and [comparison-table.md](comparison-table.md) refuses to subtract them.

## Live tracking while you play — lagtrack

For a while-you-play view (not a lab measurement): `lagtrack/` attaches to the game
window from outside the bottle and logs per-second FPS, frametime percentiles, an
**input→next-present** latency proxy from keyboard/mouse *and* controller button presses
(raw IOHID with Input Monitoring — mechanism 2 in the key finding), and the game
process's CPU/RAM, with a session summary (avg FPS, 1% low, latency p50/p95) on Ctrl-C.
Verified against a live in-bottle Wine window; a real-game controller-latency session has
not been run yet. For the true button-to-photon number use Category 2 below. Details and
honest caveats: [lagtrack/README.md](lagtrack/README.md).

## Reproduce Category 2 — button-to-photon

Full instructions in [stage2-workflow.md](stage2-workflow.md). Short version:
1. Record 240 fps slow-mo clips showing the **controller and the screen in one shot**, on a
   tripod, with a fast on-screen response and vibration off. 8–12 presses per clip.
2. Drop clips in `./clips/` and run `./stage2_measure.sh clips/`.
3. In inputLagTimer: **S** to mark the 🟦input and 🟪output rectangles, **1/2** & **3/4** to
   set thresholds above the noise floor, let it play, **ESC** to save.
4. `stage2_aggregate.py` pools all clips into a **median + spread** (single clips are noisy;
   pool ≥20 events).

## Mac-specific gotchas (that quietly corrupt measurements)

1. **Bluetooth vs USB.** Measured here: BT ≈ 68 Hz vs USB ≈ 109 Hz, with worse jitter. Always
   note the transport; never compare across it.
2. **Two access paths, two different failure modes.** GameController-path tools (browsers,
   SDL/pygame MFi, Wine's feed) are frontmost-only unless the client sets
   `shouldMonitorBackgroundEvents`. Raw `IOHIDManager` tools are instead gated by the
   **Input Monitoring permission** — no focus requirement once granted. If a tool "sees no
   input," first identify which path it uses, then apply the matching fix (focus vs
   permission) — and suspect both before the hardware.
3. **ProMotion / display refresh.** A 120/144 Hz display both caps how fast a browser-based
   poll can *observe* reports and changes the display's own latency contribution. Record the
   refresh rate; a median report interval *below* the frame time is a red flag for
   refresh-capping.
4. **Backgrounded-app throttling.** macOS throttles background apps; controller input also
   only flows to the foreground. Keep the game/tool frontmost during any measurement, or
   latency and polling both look artificially bad.
5. **Rolling shutter & output position (Category 2).** Phone cameras and displays both scan
   top-to-bottom; camera skew and where on the screen you measure can each shift the number by
   up to a frame. Keep them consistent across clips.
6. **Panel response & monitor settings (Category 2).** OLED ≫ LCD; game mode / overdrive
   change real latency. Only compare clips taken under identical display settings.

## Bonus: CrossOver / Wine log analysis

`log-analyzer/analyze.py --logs-dir logs` scans CrossOver/Wine logs for latency-relevant
signals and rates each by what it can and cannot tell you; [logs-findings.md](logs-findings.md)
is the write-up. Short version: logs give you device enumeration, frame boundaries, and
connection stability, but **not** true button-to-photon latency — that always needs the
Category-2 video method. To capture richer logs, see `log-analyzer/wine-debug-channels.md`
(note: CrossOver reads `CX_DEBUGMSG`, not `WINEDEBUG`).
