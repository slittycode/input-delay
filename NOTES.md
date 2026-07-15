# Running Notes — Controller Latency Measurement Environment

Chronological log of what was tried, what worked, and what failed. Newest entries appended per stage.

## Environment (macOS, Apple Silicon)
- Machine: Darwin 25.5.0, Apple Silicon (aarch64)
- Rust: 1.96.0 (present, but NOT needed — see Stage 1 correction)
- Homebrew: 6.0.10
- uv: 0.11.19
- Python: 3.14.0 (system); uv can manage its own (project targets >=3.10)
- SDL2: sdl2-compat 2.32.70 installed via brew (pygame bundles its own SDL2 too)
- Connected controller: **Sony DUALSHOCK 4 Wireless** (VID 0x054C / PID 0x09CC), over **Bluetooth**

---

## STAGE 1 — Polling-rate / report-interval testing (gamepadla-plus)

### Correction to the brief
- The brief described gamepadla-plus as a **Rust** project. It is **not**.
- `WyvernIXTL/gamepadla-plus` is a **Python** project: `pyproject.toml` + `uv.lock`,
  package `gamepadla_plus/` (cli.py, gui.py, common.py), built with hatchling.
- Gamepad access is via **pygame** (SDL2 under the hood). No Rust toolchain required.
- It officially supports macOS: `uv tool install --python 3.13 --managed-python gamepadla-plus`.

### What gamepadla-plus actually measures (important)
- Per its own disclaimer: it measures the delay between successive changes in analog
  **stick position**, i.e. report interval / polling behavior — NOT true button-to-photon
  input latency. Its "latency" numbers are synthetic (derived from polling interval).
- This is exactly the Stage-1 category (polling/report interval), distinct from Stage-2
  (true end-to-end latency). Documented for the Stage-3 README.

### Steps
- Cloned https://github.com/WyvernIXTL/gamepadla-plus  → ./gamepadla-plus  ✓
- `uv sync` created local venv from uv.lock (pygame 2.6.1 / SDL 2.28.4, py3.12)  ✓
- `uv run gamepadla list` → "Found 1 controllers / 0. Xbox Series X Controller"  ✓
  - NOTE: physical device is a DualShock 4, but SDL/pygame names it "Xbox Series X
    Controller" with 6 axes. macOS exposes the DS4 through Apple's GameController
    framework, which SDL maps to an Xbox-style profile. Cosmetic, but the reported
    name won't match the hardware.

### BUG in gamepadla-plus v1.7.3 (fixed locally)
- `cli.py` referenced `result["stablility"]` (misspelled); dict key is `stability`
  (common.py). Would raise KeyError AFTER collecting all 2000 samples. Patched the
  typo in gamepadla_plus/cli.py:102 so `test` prints results. (upstream bug)

### macOS gotcha: no controller input reaches pygame headlessly (SOLVED)
- `diag_axes.py` (custom): read all 6 axes ~100x/sec for 12s while sticks moved.
  FIRST RUN: all axes reported 0.0 the entire time; 0 change events.
- Cause: SDL suppresses joystick/gamepad events when its process is NOT the focused
  foreground app. Our process runs in a terminal with no SDL window → no events.
- Fix attempt log (all read live axes/buttons while sticks were supposed to be moving):
  1. Headless, no hint            → 0 changes on all 6 axes.
  2. + SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1 → 0 changes.
  3. + real SDL window (Cocoa run loop pumped) + watch buttons + SDL event queue
     (JOYAXISMOTION/JOYBUTTONDOWN) → 0 axis changes, 0 button events, 0 events.
  4. + force raw HIDAPI PS4 driver, disable MFi
     (SDL_JOYSTICK_MFI=0, SDL_JOYSTICK_HIDAPI=1, SDL_JOYSTICK_HIDAPI_PS4=1)
     → still named "Xbox Series X Controller" (HIDAPI did NOT grab it), 0 input.

### Root-cause analysis (Stage 1 blocker)
- We ARE in the user's Aqua GUI login session (`launchctl managername` = Aqua), so
  the window appeared on the real screen; not a detached/headless session.
- DS4 still connected over Bluetooth throughout.
- No Steam / third-party remapper running. BUT Apple's own GameController stack is
  active: `gamecontrollerd`, `gamecontrolleragentd`, and `XboxGamepad.dext` are
  loaded. Apple's GameController framework has CLAIMED the DS4 and re-presents it as
  an Xbox-style pad ("Xbox Series X Controller", 6 axes, 15 buttons) — which is why
  SDL's raw HIDAPI PS4 driver can't open it (exclusive) and MFi remains the backend.
- SDL enumerates the controller via its MFi/GameController backend but delivers NO
  live input events to this non-bundled Python/terminal process.
- TWO unresolved possibilities that need the user:
  a. The controller may simply not have been moved during the capture windows
     (no genuine user input has arrived this session).
  b. If it WAS moved: this is the known macOS limitation where controllers routed
     through the GameController framework don't feed SDL/pygame reliably from a
     terminal process — often needs Input Monitoring permission for the host app,
     and/or a wired USB connection, and/or running from a real foreground app.

### Stage 1 status: tool BUILDS + RUNS + ENUMERATES; live input capture BLOCKED.

- Run #5: user confirmed present with controller in-hand → STILL 0 axes / 0 buttons /
  0 SDL events over 10s. Zero *buttons* too (not just sticks) strongly implies the
  input is not reaching this process at all, rather than a stick-not-moved issue.
- Working hypothesis (now primary): the harness Bash execution context, while nominally
  in the Aqua session, is not a frontmost/activated GUI app, so Apple's GameController
  framework (which owns the DS4) never delivers input events to SDL/pygame here. The
  pygame window renders but likely never becomes the key/active app under this harness.
- Decisive test to distinguish "harness context" vs "controller/permission problem":
  run the SAME diagnostic from the user's own Terminal.app (a real user-launched
  foreground app). Wrapper written: stage1_selftest.sh (below).
- Note: a stretch of Bash calls were blocked by a transient safety-classifier outage
  ("claude-opus-4-8 temporarily unavailable"); unrelated to the controller issue.

---

## STAGE 1b — CrossOver in-bottle testing (Addition A)

Date: 2026-07-14. Tools built, tested, blocked by same root cause.

### Environment update
- CrossOver 26.2.0 installed at `/Applications/CrossOver.app` (build 39821)
- Existing bottles: "Elden Ring Test", "Skyrim SE", "The Elder Scrolls IV Oblivion Remastered", "TLOU 2"
- Controller update: now using **Xbox Series X/S Wireless Controller** (VID 045E, PID 0B13) over Bluetooth
  alongside the DS4. Xbox controller is preferred for Wine compatibility (native XInput).

### Addition A — Infrastructure built (all in `cross-over/`)
- `setup-bottle.sh` — creates Windows 10 bottle via `cxbottle` CLI
- `install-polling.sh` — downloads cakama3a/Polling.exe v1.3.1.4 into bottle
- `run-in-bottle.sh` — launches Polling.exe with WINEDEBUG channels
- `run-comparison.sh` — runs native + in-bottle, produces `comparison-table.md`
- `probe_controller.c` / `probe_controller.exe` — standalone 18KB C probe using raw XInput via ctypes
- `probe_controller.py` — same logic in Python (fallback)
- `verify-all.sh` — master verification chain (L1-L3 native + bottle L1-L2)

### Addition B — Log analysis framework (all in `log-analyzer/`)
- `analyze.py` — format-agnostic log scanner with 15 signal detectors
- `patterns.py` — detector definitions with categories, relevance ratings, explicit limitations
- `wine-debug-channels.md` — complete WINEDEBUG reference for latency analysis
- `logs-findings.md` — structured findings template
- Analyzed `Elden Ring Test.cxlog` (50KB, 50k lines) — 9 signal categories found

### CrossOver/Wine test results
- CrossOver's `wine` binary requires `--bottle <name>` flag; bare WINEPREFIX doesn't work
- probe_controller.exe works: loads xinput1_4.dll, detects controller, reads axis values
- **XInput reports zero live data** — all axis values are 0, packet=0 never increments
- Polling.exe crashes on launch: cp1252 UnicodeEncodeError in ASCII art logo
- Workaround: installed Python 3.13.2 in the Elden Ring bottle, patched Polling source
- Patched Polling runs but hangs — `joystick.get_axis()` returns zero, no changes detected
- `WINEDEBUG=+xinput,+hid,+dinput,+timestamp` log confirms:
  - `add_device` with `VID_045E&PID_0B13` at `12941.062` (Xbox controller identified)
  - `wine_xinput_hid_update` thread spawned
  - `Found gamepad L"\\\\?\\\\hid#vid_045e&pid_0b13..."` at `12942.692`
  - **No further HID reports** — controller enumerated but reports never arrive

### Root cause: same as native Stage 1
Apple's GameController framework (`gamecontrollerd`, `XboxGamepad.dext`) claims the
controller exclusively. On native macOS, pygame/SDL can't get events. On CrossOver/Wine,
Wine's HID bus driver can't open the HID device to read reports. Both paths detect the
device but receive zero live data.

### Untested workarounds
- **USB connection** may bypass GameController's exclusive claim (uses IOHID directly)
- Running a GUI game in CrossOver (fullscreen foreground) may trigger macOS to deliver events
- Third-party driver like 360Controller or ds4drv may work around Apple's framework

---

## STAGE 1b — Log analysis of the actual captured log (Addition B, empirical)

Date: 2026-07-14. Ran `log-analyzer/analyze.py --logs-dir logs` against the real file
`logs/Elden Ring Test.cxlog` (5.0 MB, 50,164 lines). Format detected: crossover_app.
9 signal categories found. Regenerated `logs-findings.md`.

### IMPORTANT provenance correction (do not overclaim)
- This log is NOT a real Elden Ring gameplay session. Line 1 shows it is the stdout+
  WINEDEBUG capture of **our own `cross-over/probe_controller.exe`** run. So every signal
  here is from the probe, not a game engine under load.
- Consequence: the analyzer template rates "XInput calls" as [DIRECT] latency relevance,
  but in THIS log that rating is misleading. See below.

### What the log empirically confirms (real, from the actual bytes)
1. Controller IS enumerated by Wine: `add_device ... device_id L"WINEXINPUT\VID_045E&PID_0B13"`
   at Wine-timestamp 12941.062 (Xbox Series X/S, VID 045E PID 0B13). Matches native enum.
2. Only **5** `XInputGetState` calls total, all in a ~0.6 s window (12942.609 → 12943.195):
   - 12942.609  index 0
   - 12942.694  index 1, 2, 3   (0.085 s later — an enumeration sweep of all 4 XInput slots)
   - 12943.195  index 0 again   (0.586 s after the first index-0 read)
   These are the probe's own "which slot has a pad?" sweep + one re-poll — NOT a steady
   200–1000 Hz game polling loop. **You cannot derive a real polling rate from this log.**
   The 586 ms gap is the probe's loop delay, not controller report interval.
3. **0** dinput `GetDeviceState` calls. **0** HID input-report reads (`IOCTL_HID_*`/read_report).
   The Windows side never pulled a single input report → consistent with the native blocker:
   the controller is claimed by Apple GameController, so Wine's HID bus gets no reports.
4. Probe exited cleanly (PROCESS_DETACH at 12947.335) — no crash, no reconnect events.

### Honest verdict on this log
- Confirms the plumbing (enum, xinput1_4 load, WINEBUS device) but contains **zero live
  input data** and **zero derivable timing metrics** for polling or latency. It documents
  the failure mode, not a measurement. To get a real in-bottle polling trace we need a
  session where XInputGetState is called continuously *and returns changing packet numbers*
  — which requires the controller to actually feed Wine (currently blocked).
- The auto-generated `logs-findings.md` [DIRECT] tag on XInput is generic; for THIS capture
  the real reading is "enumeration only, no steady-state polling." Flagged to user.

---

## ROOT CAUSE — PROVEN (2026-07-14, USB-C wired test)

Controller plugged in via USB-C. Re-ran diag: STILL 0 axes / 0 buttons. Then went to the
OS layer, which settled it:

- `ioreg -c IOHIDDevice` for the wired pad (VID 1118/0x045E, PID 2834, Transport=USB) shows:
  - `IOClass = AppleUserHIDDevice`
  - `CFBundleIdentifier = com.apple.gamecontroller.driver.XboxGamepad`
  - `IOUserClass = XboxSeriesXGamepad`, `bInterfaceClass = 255` (vendor-specific), subclass 71
  → Apple's **XboxGamepad.dext** driver extension binds the raw USB interface *itself* and
    re-exposes the pad ONLY through the GameController framework. The exclusive claim is at
    the driver-binding layer, so it is identical wired or wireless. USB does NOT bypass it.

- Confirmed downstream with SDL backend forcing:
  - `SDL_JOYSTICK_MFI=0 SDL_JOYSTICK_HIDAPI=1 SDL_JOYSTICK_HIDAPI_XBOX=1` → **0 controllers**
    (hidapi cannot open the device — the dext owns the endpoint).
  - Default (MFi backend) → enumerates as "Xbox Series X Controller" but **0 live events**.

### Definitive conclusion
On this Mac the Xbox Series X controller is readable **only** via Apple's GameController
framework (GCController API), and only by a *frontmost, activated* app that registers
GC handlers. A terminal Python/SDL process cannot be that app, so gamepadla (pygame/SDL)
gets nothing. Wine's HID bus can't open it either → Addition A blocked by the same wall.
This is a macOS platform behavior, NOT a hardware fault and NOT fixable via SDL hints/USB.

### The native path that DOES work: the browser Gamepad API
Browsers (Chrome/Safari) implement the W3C Gamepad API on top of GameController, run as
frontmost activated apps, and DO receive this controller. So `navigator.getGamepads()` is
a genuine native-macOS route to real polling data. Built a self-contained tester (`webtester/gamepad.html`) that times `gamepad.timestamp`
changes to derive report interval / polling rate / jitter, sampling with a tight
MessageChannel loop (faster than rAF).

### FIRST REAL STAGE-1 MEASUREMENT (2026-07-14) — saved to `stage1_browser_result.json`
Ran in the in-app Claude Browser (Electron/Chromium 148, Gamepad API = GameController path),
Xbox Series X/S over USB via USB2 dock, left stick rotated ~15 s:
- reports_captured: 1258 over 15.03 s
- **polling_rate ≈ 109.9 Hz** (from median interval 9.1 ms)
- interval ms: min 4.0 / median 9.1 / avg 9.87 / max 423.2 / jitter_std 16.87
- sampler_loop_hz: **337,207** → sampling is NOT the bottleneck; number is real, not undersampled.

Honest reading:
1. NOT display-capped: median 9.1 ms > 6.94 ms (144 Hz main) and > 8.33 ms (120 Hz built-in).
   If refresh-capped, median would sit at a frame time; it doesn't. min 4 ms shows sub-frame
   delivery is possible.
2. ~110 Hz is consistent with an Xbox pad's ~125 Hz nominal report rate minus GameController
   delivery overhead / occasional dropped reports.
3. The 423 ms max and inflated jitter_std are mostly artifacts of momentary stick pauses
   (no value change → no new timestamp → long gap). **Median 9.1 ms is the robust metric;**
   for a clean jitter figure, filter gaps >~50 ms or keep the stick moving without pause.
4. This is the *native-macOS GameController path* — arguably closer to what a native mac game
   sees than SDL would be. It is the Stage-1 (polling/report-interval) category, NOT
   button-to-photon (that's Stage 2).

### TRANSPORT COMPARISON (2026-07-15) — user ran 3 browser captures, saved to native-results/
All sampler_loop_hz ~220k+ (not loop-capped); medians > display frame times (not refresh-capped).

| Connection | Polling rate | Median | Min | Max  | Jitter std |
|------------|--------------|--------|-----|------|-----------|
| Bluetooth  | 67.6 Hz      | 14.8ms | 5   | 90.1 | 7.98 ms   |
| USB-C      | 109.9 Hz     | 9.1ms  | 4   | 120.4| 5.94 ms   |
| USB-A      | 108.7 Hz     | 9.2ms  | 4   | 62.4 | 4.13 ms   |

Findings:
1. Bluetooth ~halves the effective report rate (68 vs ~109 Hz; median interval 14.8 vs 9.1 ms)
   AND raises jitter (7.98 vs 4–6 ms). Clear, measurable BT penalty.
2. USB-C ≈ USB-A (~109 Hz); port/dock type is irrelevant to report rate. USB-A cleanest here
   (jitter 4.1) but within run-to-run noise.
3. Wired ~109 Hz consistent with Xbox ~125 Hz nominal minus GameController overhead.
4. Reproducible: this USB-C run (109.9 Hz / 9.1 ms) matches the earlier separate USB-C capture.
5. Recommendation for lowest input latency on this Mac: USB (either), avoid Bluetooth.
Native-side baseline for the CrossOver comparison is therefore ~109 Hz wired.

---

## STAGE 2 — Button-to-photon (inputLagTimer) — TOOLING BUILT + VERIFIED (2026-07-15)

- Cloned https://github.com/stenyak/inputLagTimer → ./inputLagTimer (Python + opencv + numpy).
- venv: `inputLagTimer/.venv` (uv, Python 3.12); installed opencv-python 5.0.0, numpy 2.5.1. ✓
- Upstream tool is interactive (mark blue/purple rects, tune thresholds, reads latency
  on-screen) and only persists a per-video `.cfg` — it does NOT save measured latencies.
- LOCAL PATCH (documented, like the gamepadla typo fix): added a block before `cap.release()`
  in inputLagTimer.py main() that writes `<video>.result.json` on exit with the latency list +
  count/median/mean/stdev/min/max. Only for file inputs (not webcam int). Parses OK.
- `stage2_aggregate.py` — pools all `*.result.json`, prints per-clip medians + pooled
  median/mean/stdev/IQR/min/max. VERIFIED with synthetic fixtures (recomputes median from raw
  events, robust to per-clip rounding). No real latency numbers invented.
- `stage2_measure.sh` — runs inputLagTimer over each clip in a dir, then aggregates.
- `stage2-workflow.md` — full recording + analysis workflow + macOS gotchas (rolling shutter,
  screen scanout position, panel response, ProMotion refresh, background throttling).

### Stage 2 status: tooling READY. Needs the user to record 240fps clips (controller + screen
in one shot) into ./clips/ and run stage2_measure.sh. No real button-to-photon number yet —
that requires the user's video (cannot be fabricated).

---

## ADDITION A — CrossOver in-bottle: FULLY DIAGNOSED (2026-07-14), input NOT achievable on this OS

Goal: get the Xbox controller feeding a CrossOver bottle so we can measure in-bottle polling
and compute the native-vs-CrossOver delta. Result: proven impossible via config on this macOS.

### What we tried and proved
1. Native `cross-over/hidprobe.c` (raw IOHIDManager — same access class as Wine's IOHID
   backend): `IOHIDManagerOpen` = OPEN_OK, device matched ("Xbox Wireless Controller",
   VID 0x045e), but **0 input reports in 12 s**. So NO raw-HID client on this Mac gets
   reports — `gamecontrollerd` consumes the stream. Wine is not uniquely broken.
2. Discovered CrossOver's `winebus.so` has an **SDL backend** (SDL_GameController* +
   bundled libSDL2 with MFi/GameController driver) besides IOHID. It was OFF
   ("SDL devices disabled in registry").
3. Enabled it: `reg add HKLM\System\CurrentControlSet\Services\winebus\Parameters
   /v "Enable SDL" /t REG_DWORD /d 1 /f` in bottle "Elden Ring Test" (via
   `wine --bottle "Elden Ring Test" --wl-app reg.exe ...`; CrossOver ignores WINEPREFIX,
   needs --bottle). Restarted wineserver.
4. Built `cross-over/probe_live.exe` (continuous XInput poller, counts packet-number
   changes over 12 s) and ran it in-bottle while moving the stick.

### Result (CX_DEBUGMSG=+timestamp,+hid,+plugplay,+xinput → /tmp/cx-sdl.log)
- SDL backend ENGAGED: `sdl_add_device ... vid 045e, pid 0b13, is_gamepad 1, is_hidraw 0`
  → SDL enumerated the pad via GameController and created a non-hidraw device. XInput saw it
  on slot 0 ("Xbox Series X Controller").
- SDL bus main loop STARTED and kept running (did not exit early).
- CrossOver's dedicated Xbox bus is EXPLICITLY DISABLED on this OS:
  `xbox_bus_init disabled: running on macOS Sequoia or later`
  `xbox_bus_wait disabled: running on macOS Sequoia or later`
- **probe_live: TOTAL polls=9333, packet-changes=0** over 12 s of active stick movement.
  No `hid` input-report writes appear in the log after device creation. → SDL enumerated
  the controller but GameController delivered **zero input events** to the background
  winedevice service process.

### Proven root cause (all layers tested on THIS machine)
| Path | Enumerates? | Live input? |
|------|-------------|-------------|
| Native raw IOHID (hidprobe)     | yes | NO (0 reports) |
| Native SDL/pygame (terminal)    | yes | NO (0 events)  |
| Browser Gamepad API (FRONTMOST) | yes | YES (~110 Hz)  |
| CrossOver winebus IOHID         | yes | NO (0 packets) |
| CrossOver winebus SDL (enabled) | yes | NO (0 packets) |

The ONLY working path is a **frontmost** app: macOS GameController delivers controller INPUT
only to the frontmost application. Wine's winebus runs in a background `winedevice` service
(never frontmost) → enumeration but no input, whether via IOHID or SDL. Additionally
CrossOver disables its native Xbox bus on macOS Sequoia+. Therefore, on this OS, an Xbox
controller claimed by Apple's XboxGamepad.dext cannot feed a CrossOver game through the
standard input path. This is a macOS + Wine-architecture limitation, NOT a fixable setting.

### Consequence for the Addition A deliverable
No live in-bottle polling number is obtainable → the native-vs-CrossOver **delta cannot be
measured** on this OS and MUST NOT be fabricated. comparison-table.md updated to state this
with the evidence. `Enable SDL=1` left in the "Elden Ring Test" bottle pending user decision
to revert (it enumerates a dead controller, so reverting is advisable).

### Realistic workarounds (UNTESTED — would need user buy-in)
1. Steam Input: native Steam (frontmost) reads the pad via GameController and exposes a
   virtual XInput controller; a virtual-HID bridge could let Wine read it. Heavy, uncertain.
2. A small frontmost helper app that reads GameController and re-emits to a virtual HID
   device (foohid / Karabiner VirtualHIDDevice) that winebus can read via hidraw.
3. Report to CodeWeavers as a CrossOver-on-Sequoia+ Xbox controller regression (xbox_bus
   disabled + SDL-background-input blocked).
4. Test whether the DualShock 4 (VID 054C) behaves differently (may still be dext-claimed).

---

## ⚠️ ADDITION A — CORRECTION (2026-07-15): input IS achievable; earlier conclusion was WRONG

The "input NOT achievable" conclusion above was a **test-harness artifact**, now disproven.

- User confirmed the controller works in their real CrossOver games. That's ground truth:
  input DOES reach the bottle.
- Root cause of my earlier zeros: every probe I ran (console `probe_live.exe`, and the
  windowless native `hidprobe`) was **windowless**, so no Wine app was ever frontmost, and
  macOS GameController withholds *input* (not enumeration) from non-frontmost apps.
- Fix: built `cross-over/probe_live_gui.exe` — a **windowed** Win32 XInput poller — plus
  `cross-over/run-gui-probe.sh`. When the USER runs it and focuses the window (like launching
  a game), input flows.

### REAL in-bottle result (2026-07-15) → cross-over-output/inbottle-result.json
Backend: default winebus **IOHID** (Enable SDL was reverted to 0). Window focused, stick moved:
- polls=11823, **packet_changes=2399**, **polling_rate=172.0 Hz**
- interval ms: min 1.02 / avg 5.82 / max 18.9
- verdict: LIVE input through CrossOver.

### Corrected root-cause model
The differentiator is a **frontmost window**, NOT the backend and NOT the OS version:
- Windowless process (console probe, hidprobe, background winedevice) → enumeration only, 0 input.
- Frontmost windowed app (browser, real game, probe_live_gui) → full input.
IOHID delivers input fine to a frontmost windowed Wine app; it only returned 0 to windowless
probes. CrossOver's Xbox-bus-disabled-on-Sequoia note is real but did NOT block input — the
default IOHID path works.

### Honest comparison caveat (see comparison-table.md)
In-bottle 172 Hz (XInput dwPacketNumber increments) vs native ~109 Hz (browser gamepad.timestamp,
Chromium-capped) are DIFFERENT measurement methods → not a clean overhead subtraction. Defensible
conclusion: CrossOver's input path is NOT a polling-rate bottleneck; it surfaces updates at least
as often as the native browser API. A true native raw-report-rate reference is unobtainable
(gamecontrollerd blocks raw HID; XInput is Windows-only).

## 2026-07-15 (evening) — MAJOR CORRECTION: background controller access WORKS

The "controller input is frontmost-only / raw HID is blocked" model above is **wrong for
background OBSERVATION**, proven by two new probes in `gcprobe/` run while the pad
(Xbox Wireless Controller, Bluetooth LE) was connected and Claude was the frontmost app:

### gcprobe.swift — GCController + shouldMonitorBackgroundEvents = true
Result: **37/37 events delivered while BACKGROUNDED** (left-stick values streamed live;
verdict line: "BACKGROUND CONTROLLER EVENTS WORK"). The earlier tests (SDL/pygame from a
terminal) never set `GCController.shouldMonitorBackgroundEvents`, the API Apple ships
exactly for this. Frontmost-only is the *default*, not a wall.

### hidmon.swift — raw IOHIDManager, from a context WITH Input Monitoring granted
Result: **110/110 raw input reports delivered while BACKGROUNDED** (usage page 0x01,
axis reports). The original hidprobe "OPEN_OK + zero reports" run was made from a
context without Input Monitoring — its own comments listed that as the alternate
suspect. Verdict: **the zero was a permission artifact, not a dext seize.**

### What this changes
- `lagtrack/` now has a `ControllerTap` (raw IOHID, button/hat presses only, kernel
  report timestamps via IOHIDValueGetTimeStamp) → **live controller→present latency**
  alongside the KB/M tap. Analog axes deliberately ignored (idle drift is not input —
  observed: the pad streams axis noise while untouched).
- What still stands: per-press samples are input→next-present (lower-bound proxy);
  true button-to-photon remains the stage2 video method. The in-bottle XInput
  windowless-while-game-frontmost question is now moot for lagtrack (native tap is
  strictly better) and remains untested.
- Caveat for the record: today's positive runs were over **Bluetooth LE**. The original
  zero-report runs were USB (XboxGamepad.dext claim documented in ioreg). Whether raw
  HID also delivers over USB with Input Monitoring granted is untested — if it doesn't,
  the GCController background path (proven above) is the fallback.

## 2026-07-15 (late) — latbudget: per-stage budget monitor + in-bottle XInput proxy

Built `latbudget/` (spec: per-stage budget, no single number, IOHIDManager report
timestamps, monotonic clocks only, 1 kHz self-test). Self-test PASSES: stats pipeline
exact at 1 kHz; live dispatch ingest 2999/2999 with p99 lag 345 µs; UDP loopback 0 %
loss, mapped-time p99 414 µs.

Stage 2 (novel): `wine/xinput_proxy.c`, a forwarding `xinput1_4.dll` that timestamps
dwPacketNumber changes at the game's own poll (QPC) and emits UDP to the host.
Verified live in the "Elden Ring Test" bottle. Discoveries that cost hours:

1. **CrossOver strips `WINEDLLOVERRIDES`** (verified via `cmd /c set` in-bottle). Use a
   per-app registry override instead: HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides
   = "native,builtin". install-proxy.sh automates it.
2. **`GetModuleFileName` masquerade**: Wine reports a builtin module under the path of
   the same-named native file found in search order — it "loaded our dll" while running
   the builtin. Only behavioral proof (hello packet / debug log) is trustworthy.
3. First in-bottle `XInputGetState` after start returns 1167 once (enum warmup), then 0.
4. dwPacketNumber freezes while no bottle window is frontmost (consistent with the
   windowless-probe finding) — in-bottle observation needs the game focused; background
   OBSERVATION on the host side (gcprobe/hidmon) is unaffected.

Stage B live (drift-only, BT LE): median 15.18 ms ≈ 66 Hz — matches the original
Bluetooth polling measurement (67.6 Hz) from a completely independent path. 109 idle
gaps correctly excluded.

## 2026-07-15 (night) — pollrate rewrite: value callbacks, live dashboards, USB truth

A separate session (DeepSeek) rewrote `--pollrate` and added live dashboards; this
session reviewed, fixed, and re-verified the work.

### The rewrite
The report-with-timestamp callback (`IOHIDDeviceRegisterInputReportWithTimeStampCallback`)
delivered **nothing over USB** on this machine — it had only ever been proven over BT LE
(the caveat recorded in the morning entry). `--pollrate` now uses
`IOHIDManagerRegisterInputValueCallback` instead: fires per element change, deduplicated
by the value's report timestamp so one HID report counts once regardless of how many
elements changed. All inputs count (sticks, buttons, triggers), not just the left stick.

New surfaces:
- `latbudget --pollrate --gui` — live AppKit dashboard (rolling-window rate, transport
  label, per-device tracking, JSON printed on close).
- `cross-over/poll_live.exe` (+ `run-poll-live.sh`) — matching in-bottle XInput
  dashboard; writes JSON to `Z:\tmp\poll-live-result.json` on close.

### Verified this session (re-run, real bytes)
DualShock 4 ("Wireless Controller", 054c:09cc) over **USB**: **250 Hz** — median
4.000 ms, jitter σ 0.021–0.035 ms across two runs (1569 reports/6.3 s, 2099/8.4 s).
The DS4 presents as generic HID (no Apple dext claims it), so raw IOHID sees its full
native rate. This also resolves the morning caveat: raw HID **does** deliver over USB
with Input Monitoring granted — the earlier USB dead-ends were the report callback,
not the transport.

### Reported by the building session, NOT yet reproduced here
1. Xbox Series pad on USB capped at **125 Hz / 8.0 ms** — attributed to
   `XboxGamepad.dext`. No Xbox pad was connected during this session's re-run.
2. winebus slices one HID report into **~1.6 dwPacketNumber increments**, inflating
   naive in-bottle rates. (Consistent with the documented 172>109 bracket: packet
   changes need not be 1:1 with HID reports.) The only in-bottle result JSON on disk
   was a zero-data run — a real focused-window capture is still owed.

### Fixes applied on review
- `poll_live.c` wrote a **median-based** rate to JSON while displaying an avg-based
  one; with the sliced (bimodal) interval distribution the median is meaningless.
  JSON now uses avg == packet-changes/sec, the state-update rate the game sees.
- `poll_live.c` wrote a zero-filled JSON when no controller was ever seen (found the
  artifact on disk). It now writes nothing when there is no data.
- `intervals_captured` was `reports - 1` (a guess); it is now the actual count of
  non-excluded intervals, and the stdout JSON schema matches the `--out` schema.
- `run-poll-live.sh` builds `poll_live.exe` if missing/stale (the .exe is gitignored).
- `latbudget/README.md`'s example output was replaced with a real capture — the old
  example showed an "Xbox Series X Controller" at 251 Hz, which matches no run on
  record and contradicts the 125 Hz dext-cap report.
