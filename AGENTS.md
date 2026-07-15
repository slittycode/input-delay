# AGENTS.md — input-delay

Controller input-latency measurement environment for macOS (Apple Silicon). Polyglot, multi-tool — no single build system. The governing rule: **no latency number is invented.** Every figure comes from an actual run. Unmeasurable gaps are stated as such.

## Primary instruction sources

- **WORKFLOW.md** — commit discipline, build gates, verification protocol (read it first)
- **README.md** — project overview, measurement categories, Mac-specific gotchas
- **NOTES.md** — chronological log of everything tried, including dead ends and root causes
- **STATUS.md** — current project status

## Build system

There is no unified build. Each component compiles independently:

| Component | Build command | Notes |
|---|---|---|
| `lagtrack/` | `swift build -c release` (in directory) | Swift SPM, macOS 14+ |
| `latbudget/` | `swift build -c release` (in directory) | Swift SPM, macOS 14+ |
| `gcprobe/` | `xcrun swiftc -O <file>.swift -o <binary>` | Standalone Swift files |
| `latbudget/wine/` | `./build-proxy.sh` | mingw-w64 cross-compile, produces `xinput1_4.dll` |
| `gamepadla-plus/` | `uv build` | Python 3.10+, hatchling |
| `webtester/` | None — static HTML, serve with `python3 -m http.server 8777` | |

## Pre-commit build gate

`.githooks/pre-commit` runs `swift build -c release` for both `latbudget` and `lagtrack` before every commit. If either fails, the commit is blocked. Enable with:
```
git config core.hooksPath .githooks
```
Never `--no-verify` without owning the failure.

## Testing (empirical, not unit tests)

This project uses empirical verification, not test frameworks:

```bash
# 1 kHz harness proof (3 checks: stats pipeline, live dispatch, UDP loopback)
./latbudget/.build/release/latbudget --selftest

# Validate --pollrate mode against known BT reference (60-72 Hz)
./latbudget/validate-pollrate.sh

# Master verification chain (manual interaction required for some layers)
./verify-all.sh [--bottle <name>]

# Browser Gamepad API tester (primary Category 1 measurement path)
cd webtester && python3 -m http.server 8777
```

## Critical Swift/macOS quirks

- **`NSApplication.shared` must be touched** before `SCContentFilter` in CLI tools — otherwise crashes with `CGS_REQUIRE_INIT`. Both `lagtrack` and `latbudget` do this at startup.
- **ScreenCaptureKit is capped at display refresh** — a game rendering 300 fps shows as 144 on a 144 Hz display. This is inherent; no tool can bypass it.
- **All timing uses `mach_absolute_time` exclusively.** Never introduce `Date`, `time.time()`, or any wall-clock source into measurement paths.
- **`XboxGamepad.dext` claims the controller at IOKit level** — two access paths with different rules:
  - GameController.framework: **frontmost-only** (unless `shouldMonitorBackgroundEvents = true`)
  - Raw IOHIDManager: **gated by Input Monitoring TCC permission** (not focus-limited)
- **`CGEventTimestamp` is ambiguous** — documented as nanoseconds but ships as raw mach ticks on some hardware. `InputTap` uses a heuristic.

## CrossOver/Wine quirks

- **CrossOver strips `WINEDLLOVERRIDES`** from the environment. Use per-app registry override instead: `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides = "native,builtin"`
- **`GetModuleFileName` returns the native file's path** even when Wine is using its builtin module — masquerading.
- **First `XInputGetState` after start returns 1167** (`ERROR_DEVICE_NOT_CONNECTED`) — enumeration warmup, not a real disconnect.
- **`dwPacketNumber` only advances while a bottle window is frontmost.**
- **CrossOver logs use `CX_DEBUGMSG`**, not `WINEDEBUG`.
- **POSIX `sed` on macOS lacks `-P` (Perl regex)** — scripts must be compatible with both GNU and BSD `sed`.

## Measurement conventions

- **Never invent numbers.** If a measurement can't be taken cleanly, state the gap. Use `latbudget`'s `UNMEASURED` pattern.
- **Report median + spread**, not single measurements (camera quantization and panel variance make single values misleading).
- **Jitter (std dev) matters more than mean** for feel.
- **Exclude idle gaps** (>200ms between stick movements) from cadence stats — count them separately.
- **Report sampler loop rate alongside results** — if loop rate approaches polling rate, the number is loop-capped and untrustworthy.
- **Browser Gamepad API caps at ~110 Hz** on Chromium — undercounts true USB report rate. Note the cap in any browser-based measurement.
- **Don't sum per-stage latencies into one number.** `latbudget` reports a budget per stage; missing stages say `UNMEASURED`.

## Project conventions

- **One change class per commit** (docs-only / validated fix / new feature) — never bundle risk levels.
- **`verify-all.sh` must be re-run after any change to it**, on the committed bytes, not a prior run.
- **Regenerate `FILES.md` after file adds/renames:** `./scripts/update-files-md.sh`
- **No force-push, no amend, no skip hooks.**

## Vendored sub-projects (not to be modified)

- `gamepadla-plus/` — upstream clone, own `.git`, own CI workflows
- `inputLagTimer/` — upstream clone, own `.git`, patched to write `result.json` sidecars
