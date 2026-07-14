# CrossOver Input-Path Overhead: Native vs In-Bottle

> Status: **MEASURED.** CrossOver DOES deliver live controller input (once a bottle app is
> frontmost). A clean overhead *delta* is not computable because the two sides use different
> measurement methods — see the caveat. Full evidence in `../NOTES.md` (Addition A).

## Results

| Metric | Native (macOS, browser Gamepad API) | CrossOver in-bottle (XInput) |
|--------|-------------------------------------|------------------------------|
| Effective update rate | **~109 Hz** wired (`native-results/gamepad-result-usb-c.json`) | **172 Hz** (`cross-over-output/inbottle-result.json`) |
| Interval min (ms) | 4.0 | 1.02 |
| Interval avg/median (ms) | 9.1 (median) | 5.82 (avg) |
| Interval max (ms) | 120 | 18.9 |
| Measures | `gamepad.timestamp` deltas | `dwPacketNumber` increments |

## Why these numbers can't be subtracted for a clean "overhead" (important)

The in-bottle rate (172 Hz) is *higher* than the native browser rate (109 Hz). CrossOver is
**not** magically faster — the two methods measure different things:

1. **Native** uses the browser Gamepad API, whose `gamepad.timestamp` updates at Chromium's
   **capped internal gamepad cadence** (~110 Hz). It almost certainly **under-counts** the
   controller's true report rate.
2. **In-bottle** counts XInput `dwPacketNumber` increments, which winebus bumps per HID
   report — surfacing updates the browser API hides.

So a `bottle − native` subtraction would be measuring the browser's cap, not CrossOver's
overhead. A true native reference (raw HID report rate, same method as XInput) is **not
obtainable on this Mac**: `gamecontrollerd` blocks raw-HID access natively (proven by
`hidprobe`: OPEN_OK + 0 reports), and XInput is Windows-only.

## What we CAN conclude (honestly)

1. **CrossOver delivers live controller input** — 2399 packet changes, 172 Hz, avg 5.82 ms.
   Proven, not assumed. (Matches the user's real-world experience that controllers work
   in their CrossOver games.)
2. **CrossOver's input path is not a polling-rate bottleneck.** It surfaces controller
   updates at least as frequently as — in fact more frequently than — the native browser
   API exposes. No evidence of CrossOver adding per-report latency at the polling layer.
3. The polling layer is only part of end-to-end latency. Any Wine translation cost, plus
   render/present, still requires the Stage 2 button-to-photon method to quantify.

## Critical method note (why the earlier "blocked" conclusion was WRONG)

An earlier draft of this file concluded input was unachievable in the bottle. That was a
**test-harness artifact**: the probe was a windowless console app, so no Wine app was ever
frontmost, and macOS GameController withholds *input* from non-frontmost apps. A **windowed**
probe (`probe_live_gui.exe`, run via `run-gui-probe.sh` and focused by the user) receives
input normally — exactly like a real game. Enumeration-only paths (windowless IOHID/SDL) still
show 0, which is consistent: the differentiator is a **frontmost window**, not the backend.

## What a delta *would* have measured (for reference)

- **Polling Rate** = stick-position updates/sec the game sees.
- **Interval** = time between successive report changes.
- **Delta** = CrossOver's input-path overhead (bottle minus native).

## What this never measures (regardless)

- True button-to-photon latency (Stage 2 video/hardware method).
- Game-engine input processing time.
- Display latency (pixel response, scanout).

## Reproduce

```bash
# Native raw-HID (demonstrates gamecontrollerd blocks raw HID: OPEN_OK + 0 reports):
cd cross-over && clang hidprobe.c -o hidprobe -framework IOKit -framework CoreFoundation && ./hidprobe

# Native polling rate (real number): open webtester/gamepad.html in a browser, Start,
# rotate left stick 15s, Stop. Saved examples in native-results/.

# In-bottle CrossOver polling rate (the 172 Hz result) — MUST be run from a real terminal
# so the window can be focused (winebus only gets input when a Wine app is frontmost):
x86_64-w64-mingw32-gcc -O2 -mwindows -o probe_live_gui.exe probe_live_gui.c
./run-gui-probe.sh    # click the window, rotate the left stick ~15s, read the result
```

> Note: the default winebus IOHID backend is what delivered the 172 Hz result — `Enable SDL`
> is NOT required and was reverted to 0. The windowless `probe_live.exe` / SDL experiments
> only show 0 because they never bring a window frontmost; they are kept as diagnostics.
