# latbudget — CrossOver input-latency BUDGET monitor

Reports a **per-stage latency budget** with explicit unmeasured gaps. It never prints a
single "input lag: X ms" number: software cannot measure button-to-photon, so this tool
refuses to pretend otherwise. Stages are never summed.

```
[A] in-controller scan + radio ......... UNMEASURED (hardware; context bounds stated)
[B] host HID report cadence ............ MEASURED  median / p99 / jitter σ / idle gaps
[C] host HID → XInput packet at poll ... MEASURABLE (in-bottle proxy DLL + clock sync)
[D] game-observed packet → present ..... MEASURABLE (lower bound; pipelining unmeasured)
[E] present → photon ................... UNMEASURED (≤ 1 refresh + panel response)
```

> **Status (2026-07-15): no real-game budget has been captured yet.** Every link is
> individually verified — self-test PASS at 1 kHz, the proxy loads/forwards/timestamps
> inside a real bottle and its packets reach the collector with sub-ms clock sync, and
> stage B measured live at ~66 Hz over BT LE — but **[C] and [D] have zero samples from
> an actual play session**. "Works end to end" is the strongest claim this tool has
> earned so far; the first real run (install the proxy for a game, play, Ctrl-C) replaces
> this note with numbers.

## Hard-constraint compliance

1. **No single number** — the report is per-stage; unmeasured stages say UNMEASURED.
2. **No SDL/pygame** — Stage B uses `IOHIDManager` with
   `IOHIDDeviceRegisterInputReportWithTimeStampCallback`: the **kernel's own report
   timestamp**, never wall-clock-on-arrival. Harness delivery lag is reported
   separately (p50/p99 µs) so overhead is visible, not folded in.
3. **Monotonic clocks only** — `mach_absolute_time` on the host, `QueryPerformanceCounter`
   in the bottle (mach-based under Wine). No `Date`, no `time.time()` anywhere in the
   measurement path.
4. **Poll loop provably not the bottleneck** — `latbudget --selftest` drives the exact
   ingest paths with a 1000 Hz source. Measured on this machine (2026-07-15):
   - stats pipeline: median 1.0000 ms, jitter σ 0.00000 ms — PASS
   - live 1 kHz via dispatch hop: 2999/2999 events, ingest lag p50 234 µs, p99 345 µs — PASS
   - UDP loopback at 1 kHz: 0.0 % loss, mapped-time error p99 414 µs — PASS

## Usage

```bash
swift build -c release
./.build/release/latbudget --selftest        # prove the harness first
./.build/release/latbudget "Elden"           # stages B + C + D (D needs the window)
# play; live line every 2 s; Ctrl-C prints the budget
```

Permissions: Input Monitoring (stage B) and Screen Recording (stage D) for your terminal.

## Stage 1 — host HID (stage B)

Raw input **reports** per device (not per-element values). Median, p99, and **jitter
(σ)** — jitter matters more than the mean for feel. A still stick sends no reports:
intervals above 200 ms are counted as *idle gaps* and excluded from cadence stats, so
quiet periods can't fake good numbers. Meaningful cadence requires active stick
movement; idle drift produces sparse bursts with inflated σ.

## Stage 2 — inside the bottle (stage C, the novel part)

`wine/xinput_proxy.c` builds a drop-in `xinput1_4.dll` (mingw-w64) that forwards every
call to the builtin XInput and, on each `dwPacketNumber` change **observed at the
game's own poll**, stamps `QueryPerformanceCounter` and emits a 40-byte UDP packet to
the host collector (127.0.0.1:4517). No thread of its own, no polling of its own — it
rides the game's calls, so the timestamp is the moment the game could first *see* the
new state (deliberately includes waiting for the game's poll cadence).

**Clock correlation:** Wine's QPC is mach-based, so `host_arrival − qpc` = constant
offset + non-negative loopback noise; the running minimum converges on the true offset.
Self-test bound: p99 mapped-time error 414 µs.

**Install (per game, reversible, bottle otherwise untouched):**

```bash
./wine/install-proxy.sh "Elden Ring Test" "/path/to/game-dir" "eldenring.exe"
# --remove with the same args uninstalls (deletes dll + registry value)
```

Hard-won CrossOver facts (all verified 2026-07-15):

1. **CrossOver strips `WINEDLLOVERRIDES` from the environment.** The override must be a
   per-app registry value: `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides` →
   `xinput1_4 = native,builtin`. The install script does this.
2. **Wine masquerades builtin module paths.** `GetModuleFileName` on a loaded builtin
   returns the path of the same-named native file found in the search order — you
   cannot trust it to tell you which DLL actually loaded. Our proxy proves itself by
   emitting a hello packet instead. `wine/diag_xinput.exe` exists for this check.
3. The proxy loads the real XInput via the system32 fakedll path (self-load guarded,
   falls back to `xinput9_1_0.dll`).
4. First `XInputGetState` after process start can return `ERROR_DEVICE_NOT_CONNECTED`
   once (enumeration warmup); it settles by the next poll.
5. `dwPacketNumber` only advances while a window of the bottle is frontmost — stage C
   therefore measures during actual play, which is the condition you care about anyway.

## Honest limits

1. [C] includes the game's poll wait by design; it is the game-visible boundary, not
   transport alone.
2. [D] is a lower bound — the next present need not contain the input's effect (games
   pipeline 1–3 frames).
3. [B] cadence ≠ latency: it bounds the *waiting* cost (uniform 0..interval).
4. True button-to-photon still requires the stage2 240 fps video method
   (`../stage2-workflow.md`). This tool tells you **where** budget is being spent and
   what changed between configs; the video tells you the absolute total.

## Files

```
Sources/latbudget/main.swift        orchestrator, correlator, budget report
Sources/latbudget/HIDStage.swift    stage B (report timestamps, idle-gap handling)
Sources/latbudget/BottleLink.swift  stage C receiver + qpc↔mach sync
Sources/latbudget/PresentStage.swift stage D boundary (SCK displayTime)
Sources/latbudget/SelfTest.swift    the 1000 Hz proof (--selftest)
Sources/latbudget/Stats.swift       mach time, percentiles, jitter, IntervalSeries
wine/xinput_proxy.c                 the in-bottle proxy DLL (+ .def, build/install)
wine/diag_xinput.exe                which-xinput-really-loaded diagnostic
wine/udp_test.exe                   bottle→host UDP path check
```
