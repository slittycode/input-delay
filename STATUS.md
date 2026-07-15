# Project Status — Controller Input-Latency Measurement (macOS, Apple Silicon)

_Last updated: 2026-07-15._ A plain-language summary of where this project got to, what's
real, what's left, and the important things we learned. For the how-to see
[README.md](README.md); for the blow-by-blow log including dead ends see [NOTES.md](NOTES.md).

## The goal

Build an empirical environment to measure game-controller performance on macOS, separating
two things people conflate:
- **Category 1 — polling / report interval:** how often the controller reports (Hz) and how
  evenly (jitter).
- **Category 2 — button-to-photon:** the true end-to-end delay from a physical press to the
  screen reacting.

Plus two additions: measure the controller **as CrossOver sees it** (Wine input path), and
analyze **CrossOver/Wine logs** for latency signal. Governing rule throughout: **no number is
invented — every figure comes from an actual run.**

## Where we got to — at a glance

| Piece | Status | Real result |
|---|---|---|
| Stage 1 — native polling | ✅ Done | BT 68 Hz / USB-C 110 Hz / USB-A 109 Hz |
| Addition A — CrossOver in-bottle | ✅ Done | 172 Hz live; no polling penalty |
| Addition B — log analysis | ✅ Done | signal-vs-limitation write-up |
| Stage 2 — button-to-photon | ✅ Tooling built + verified | ⏳ needs user's 240 fps clips |
| Stage 3 — README | ✅ Done | full reproduction guide |
| lagtrack — live tracker | ✅ Built + verified | ~150 fps read from a live Wine window; tool costs ~5% CPU |
| lagtrack — HUD overlay + on-demand monitor.sh | ✅ Built | click-through top-bar HUD w/ instant per-press latency; Metal HUD per-run env |
| Controller re-test (gcprobe/hidmon) | ✅ Done | **background controller access WORKS** — both probes 100% background delivery |
| lagtrack ControllerTap — live pad latency | ✅ Built | raw-HID button presses, kernel timestamps; first real-game run pending |
| latbudget — per-stage budget monitor | ✅ Built + self-test PASS | stages A–E, 1 kHz harness proof, stage B live at 66 Hz |
| latbudget in-bottle XInput proxy | ✅ Verified in bottle | per-app registry override (CrossOver strips WINEDLLOVERRIDES); first real-game run pending |
| latbudget --pollrate + live dashboards | ✅ Built + re-verified | raw IOHID, no caps: DS4 USB **250 Hz** verified; Xbox 125 Hz (dext cap) reported, pending re-run |

## What's real (measurements we actually captured)

### Category 1 — native polling, by connection ([native-results/](native-results/))
| Connection | Polling rate | Median interval | Jitter (std) |
|---|---|---|---|
| Bluetooth | **67.6 Hz** | 14.8 ms | 7.98 ms |
| USB-C | **109.9 Hz** | 9.1 ms | 5.94 ms |
| USB-A | **108.7 Hz** | 9.2 ms | 4.13 ms |

Raw-IOHID addendum (2026-07-15 night, `latbudget --pollrate`, no browser/SDL caps):
DualShock 4 over USB = **250 Hz** (median 4.000 ms, jitter σ 0.02–0.04 ms) — the DS4
presents as generic HID, so nothing caps it. The ~110 Hz USB figures above came
through framework-mediated paths (SDL/browser) and are not the pad's ceiling.
Reported but not yet reproduced: Xbox Series pad held to **125 Hz** on USB by
`XboxGamepad.dext`.

Trustworthy: sampler loop ran ~220,000 Hz (not loop-capped) and medians exceed the display
frame time (not refresh-capped). Reproducible across separate runs.

### Category 1 — CrossOver in-bottle ([cross-over-output/inbottle-result.json](cross-over-output/inbottle-result.json))
172 Hz, avg 5.82 ms interval, 2399 packet changes — **live input confirmed through Wine.**

## The three things we learned (all proven, not assumed)

1. **On this Mac the controller only feeds the frontmost app *by default*.** Apple's
   `XboxGamepad.dext` claims the pad at the IOKit level, and GameController delivers input
   only to the foreground application. We proved every layer:
   - raw IOHID (`hidprobe`) → opens the device, **0 reports**;
   - SDL/pygame from a terminal → enumerates, **0 events**;
   - browser (frontmost) → **works, ~110 Hz**;
   - Wine background bus → enumerates, **0 packets**; windowed Wine app → **works, 172 Hz**.
   **2026-07-15 correction:** background *observation* works after all — proven by
   `gcprobe/` (GCController with `shouldMonitorBackgroundEvents`: 37/37 events in the
   background) and `hidmon` (raw IOHID with **Input Monitoring granted**: 110/110 reports
   in the background — the old zero was a permission artifact). Details in NOTES.md;
   lagtrack's live controller tap is built on this.

2. **Use USB, not Bluetooth.** Bluetooth roughly halves the report rate (68 vs 109 Hz) and
   worsens jitter. USB-C and USB-A are equivalent.

3. **CrossOver adds no polling-rate penalty.** The in-bottle path delivers updates at least as
   often as the native browser API exposes.

## Honest caveats (things we deliberately did NOT overclaim)

- **Native vs CrossOver is not a clean subtraction.** Native (~110 Hz) is measured via the
  browser Gamepad API, which Chromium **caps** (~110 Hz), so it under-counts the true rate.
  In-bottle (172 Hz) counts XInput packet increments. Different methods → we report both and
  the direction (CrossOver not a bottleneck), but not a fabricated "overhead = X ms" number.
  A true native raw-report reference is **unobtainable** here (gamecontrollerd blocks raw HID;
  XInput is Windows-only).
- **A conclusion we had to correct:** an earlier write-up said CrossOver input was "not
  achievable on this OS." That was **wrong** — a test-harness artifact from running a
  *windowless* probe. A *windowed* probe gets full input, matching that your real games work.
  Both [comparison-table.md](comparison-table.md) and [NOTES.md](NOTES.md) were corrected.
- **Category 2 has no number yet** because it requires video we can't fabricate.

## What was built (the tooling)

- `webtester/gamepad.html` — browser Gamepad-API polling tester (the working native path).
- `cross-over/hidprobe.c` — native IOHID probe that proved raw-HID is blocked.
- `cross-over/probe_live_gui.exe` + `run-gui-probe.sh` — windowed in-bottle XInput poller.
- `gamepadla-plus/` — cloned + fixed an upstream typo bug; builds and enumerates.
- `inputLagTimer/` — cloned, venv'd (opencv + numpy), **patched** to write a
  `<clip>.result.json` per video (upstream only shows stats on-screen).
- `stage2_measure.sh` + `stage2_aggregate.py` — run inputLagTimer over multiple clips and pool
  them into a median + spread (verified with fixtures).
- `log-analyzer/analyze.py` — CrossOver/Wine log scanner, rating each signal by usefulness.
- `lagtrack/` — **live while-you-play tracker** (Swift + ScreenCaptureKit): per-second FPS,
  frametime percentiles, KB/M input→next-present latency proxy, game-process CPU/RAM, CSV
  log + session summary (avg / 1% low / latency p50/p95). Fully external — no injection into
  the bottle. Verified live against an in-bottle Wine window; the tool itself costs ~5% of one
  core. Cannot see controller events (frontmost-only delivery — see finding #1); controller
  button-to-photon remains the stage2 video method.

## Documents

- [README.md](README.md) — the two categories, how to reproduce each, Mac gotchas.
- [comparison-table.md](comparison-table.md) — native vs in-bottle, with the method caveat.
- [stage2-workflow.md](stage2-workflow.md) — recording + analyzing button-to-photon clips.
- [logs-findings.md](logs-findings.md) — what CrossOver logs can and cannot tell us.
- [NOTES.md](NOTES.md) — chronological log of everything tried, including failures.

## What's left (one user action)

Record a few **240 fps slo-mo clips** (controller + screen in one shot, tripod, vibration
off), drop them in `./clips/`, and run `./stage2_measure.sh clips/`. That produces the only
missing number — the true button-to-photon latency — and completes the picture. Guide:
[stage2-workflow.md](stage2-workflow.md).
