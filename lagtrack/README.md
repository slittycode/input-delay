# lagtrack — live FPS / frametime / input-delay tracker

A single small Swift CLI that watches a game window from the **outside** — no injection,
no Wine hooks, nothing loaded into the CrossOver bottle — so it works identically with
D3DMetal, DXVK, or GL rendering. Measured overhead of lagtrack itself: **~5% of one core,
~30 MB RSS** (verified with `ps` during a live capture).

What it measures, live, once per second:

| Column | Source | Meaning |
|---|---|---|
| FPS, ft p50/p95/max | ScreenCaptureKit frame callbacks (`displayTime`) | Presented-frame cadence of the window |
| in→present | CGEventTap (KB/M) **and raw-HID controller tap** → next presented frame | Input-delay proxy, see caveats |
| CPU / mem | `proc_pid_rusage` on the game's pid, 1 Hz | What the game process costs |

The controller tap listens to raw HID reports (proven to arrive in the background once
Input Monitoring is granted — see `../NOTES.md` 2026-07-15 correction), counts **button
and d-pad presses only** (analog drift is not input), and timestamps with the kernel's
own report time (`IOHIDValueGetTimeStamp`).

Everything is also appended to a CSV (`sessions/<timestamp>.csv`) and summarized
(avg FPS, 1% low, frametime percentiles, latency percentiles) on Ctrl-C.

## Usage

```bash
swift build -c release            # once; binary at .build/release/lagtrack

# 1. start your game in CrossOver, then find its window:
./.build/release/lagtrack --list

# 2. attach by title or app-name substring (largest matching window wins):
./.build/release/lagtrack "Elden"

# play; watch the live line; Ctrl-C for the session summary + CSV path
```

Options:

- `--overlay` — Metal-HUD-style on-screen stats bar at the top of the main display
  (verified on-screen via CGWindowList at layer 1000). Borderless, click-through,
  non-activating panel, so the game keeps focus — and with it keyboard/controller
  input — and it floats above fullscreen Spaces. The right edge shows an **instant
  per-press readout**: the moment a key/click resolves against a presented frame, its
  individual latency appears (`⌨ 34 ms`), color-coded green < 40 ms, yellow < 80 ms,
  red beyond.
  Pair it with CrossOver's own "Performance HUD" bottle setting if you also want
  engine-level (refresh-uncapped) FPS drawn by Metal inside the game.
- `--fps-only` — skip the input tap (and the Input Monitoring permission).
- `--pid <pid>` — attach by owning process instead of title.
- `--csv <path>` — log location (default `sessions/<timestamp>.csv` under the cwd).
- `--no-focus-gate` — by default input events only count while the game is the
  frontmost app, so typing elsewhere can't pollute the latency numbers. This turns
  the gate off (use it if CrossOver's window ownership makes the pid check misfire —
  symptom: `in→present --` forever even though you're pressing keys in-game).

## On-demand monitoring (nothing permanently engaged)

`monitor.sh` wraps the whole thing into one command for "I want to watch THIS run":

```bash
./monitor.sh "Skyrim SE" "C:\\path\\to\\SkyrimSELauncher.exe"   # launch + monitor
./monitor.sh --attach "Skyrim"                                   # game already running
```

The launch form starts the program with Apple's **Metal Performance HUD enabled for
that run only** (`MTL_HUD_ENABLED=1` in the process environment — the bottle config is
never touched), waits for the window, and attaches the lagtrack overlay. You get both
HUDs at once: Metal's engine-level FPS (D3D/Metal games only; GDI windows won't show
it) and lagtrack's compositor FPS + input delay + CSV log. Ctrl-C detaches and prints
the session summary; the game keeps running.

## Permissions (one-time)

System Settings → Privacy & Security, grant to the **terminal you run lagtrack from**,
then relaunch the terminal:

1. **Screen Recording** — required. Frame timing comes from ScreenCaptureKit.
2. **Input Monitoring** — required unless `--fps-only`.

macOS may periodically re-confirm screen capture with a dialog; that's the OS, not lagtrack.

## How the numbers are made (and their honest limits)

1. **FPS** counts frames the compositor actually presented for the window
   (ScreenCaptureKit only delivers a frame when the content changed; duplicate
   `displayTime`s are dropped). Consequence: the reading is **capped at your display's
   refresh rate** — a game rendering 300 fps on a 144 Hz display reads as 144. This is
   true of any external tool; for uncapped engine-side rates you'd need an in-process
   overlay.
2. **in→present** is the time from the HID event (hardware timestamp when available,
   sanity-checked against the mach clock) to the next frame the compositor presented.
   It is a **lower-bound proxy**: the next presented frame may not yet contain that
   input's effect (the game might still be simulating it). True button-to-photon for
   this project remains the stage2 240 fps video method (`../stage2-workflow.md`).
3. **Controller presses are live** (2026-07-15): raw HID reports reach a background
   process once Input Monitoring is granted — the earlier "impossible" was a permission
   artifact (`../NOTES.md`). Caveat: proven over Bluetooth LE; if a USB connection turns
   out not to deliver raw reports, the fallback is the also-proven
   `GCController.shouldMonitorBackgroundEvents` path (`../gcprobe/gcprobe.swift`).
4. **1% low** is `1000 / p99(frametime)` over the whole session.
5. Sessions of a few hours are fine: stats keep one `Double` per frame
   (~10 MB per 3 h at 120 fps).

## Design notes

- Capture output is scaled to 160×90 BGRA — we never look at pixels, only at frame
  timestamps, so GPU/memory cost stays negligible.
- The event tap is **listen-only** and drops key auto-repeats.
- If the capture stream dies (games recreate their window on resolution/fullscreen
  changes), lagtrack re-searches for the same title for 30 s and reattaches, marking a
  discontinuity so the gap doesn't fake a giant frametime.
- A bare CLI process has no window-server connection and `SCContentFilter` asserts
  (`CGS_REQUIRE_INIT`); lagtrack touches `NSApplication.shared` at startup to create one.

## Files

```
Package.swift               SPM manifest (macOS 14+)
Sources/lagtrack/main.swift     args, session orchestration, ticker, summary
Sources/lagtrack/Capture.swift  window finding + ScreenCaptureKit stream
Sources/lagtrack/InputTap.swift listen-only CGEventTap, timestamp calibration
Sources/lagtrack/Stats.swift    tracker, percentiles, rusage sampling, CSV
```
