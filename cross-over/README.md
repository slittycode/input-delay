# CrossOver In-Bottle Controller Polling

## Purpose

Measures the controller's polling/report behavior **after** Wine's input translation,
to quantify CrossOver's input-path overhead. By comparing native macOS HID polling
vs. what a Windows game sees inside the bottle, we compute the delta: how much
delay and jitter CrossOver adds between the hardware and the game.

## Prerequisites

- CrossOver 24+ installed at `/Applications/CrossOver.app`
- Xbox Series X/S controller connected via Bluetooth (or USB)
- This project's `gamepadla-plus` (for the native comparison)
- 5 minutes per test run

## Verification First — Run the Master Chain

Before running any polling tests, verify the controller input path at every layer:

```bash
# Native layers only:
./verify-all.sh

# With CrossOver bottle (after creating it manually via CrossOver GUI):
./verify-all.sh --bottle <your-bottle-name>
```

See `verify-all.sh` output for clear pass/fail at each layer.

## Quick Start

```bash
# 0. Verify the full input path first
./verify-all.sh --bottle <your-bottle-name>

# 1. Create the bottle (once)
./setup-bottle.sh

# 2. Download Polling.exe into the bottle (once)
./install-polling.sh

# 3. Quick probe: is the controller visible inside Wine? (2 seconds)
#    Standalone 18KB .exe, no dependencies needed.
export WINEPREFIX="$HOME/Library/Application Support/CrossOver/Bottles/<your-bottle-name>"
wine C:\polling\probe_controller.exe

# 4. Run the in-bottle test (interactive)
./run-in-bottle.sh

# 5. Run both native + in-bottle, produce comparison table
./run-comparison.sh
```

## What Each Script Does

### `setup-bottle.sh`
Creates a clean Windows 10 64-bit bottle named `input-delay` using CrossOver's
`cxbottle` CLI. Does NOT install any extra Wine packages. The bottle lives at
`~/Library/Application Support/CrossOver/Bottles/input-delay`.

### `install-polling.sh`
Downloads `cakama3a/Polling` v1.3.1.4 (`Polling.exe`, 28MB PyInstaller bundle)
from GitHub Releases. Copies it to `C:\polling\Polling.exe` inside the bottle.

### `probe_controller.exe` / `probe_controller.c`
Standalone 18KB XInput probe that runs **inside** the bottle with zero dependencies.
Compiled from C with mingw-w64. Calls `XInputGetState` — the same API Xbox controller
games use. Returns clear exit codes and tells you if live data is flowing.

```bash
# Run inside the bottle (2 seconds, no heavy CLI UI):
export WINEPREFIX="~/Library/Application Support/CrossOver/Bottles/<name>"
wine C:\polling\probe_controller.exe

# Output:
#   XInput DLL: xinput1_4
#   Player 0: CONNECTED (packet=42)
#     Buttons=0x0000 LT=  0 RT=255  LX= -123 LY=+8765 ...
#   LIVE: axis/button values changed between reads — data IS flowing.
```

The C source (`probe_controller.c`) is included. Recompile with:
```bash
x86_64-w64-mingw32-gcc -O2 -o probe_controller.exe probe_controller.c
```

No Python needed in the bottle. The probe is self-contained.

### `run-in-bottle.sh`
Launches `Polling.exe` inside the bottle with `WINEDEBUG=+dinput,+hid,+xinput,+timestamp`
for diagnostic output. This is **interactive** — you must follow the Polling CLI
prompts to select your controller and rotate the stick. Output goes to
`cross-over-output/`.

### `run-comparison.sh`
The master script:
1. Runs gamepadla-plus natively (Phase 1)
2. Runs Polling.exe in the bottle (Phase 2)
3. Parses both JSON outputs and writes `comparison-table.md` (Phase 3)

## Expected Output

`comparison-table.md` contains a side-by-side table:

| Metric | Native (macOS) | CrossOver (Wine) | Delta |
|--------|---------------|------------------|-------|
| Polling Rate (Hz) | ~250 | ~N | X |
| Interval Avg (ms) | ~4 | ~N | X |
| Jitter (ms) | ~0.5 | ~N | X |

Positive delta on interval columns = CrossOver adds that many milliseconds.

## What the Delta Means

The delta between native and in-bottle polling rate approximates CrossOver's
**input-path overhead** — the time Wine spends translating controller reports
between the macOS HID layer and the Windows game's DirectInput/XInput API call.

This is NOT true button-to-photon latency (Stage 2). It measures:
- How often the controller report changes are visible inside the bottle
- How much timing consistency is lost through Wine's translation

## Troubleshooting

### "No controllers found" inside the bottle
1. Run `./verify-all.sh --bottle <name>` first — it tests each layer independently
   and will pinpoint where the chain breaks.
2. Use the fast probe first: `wine python C:\polling\probe_controller.py` — takes
   2 seconds and tests XInput directly without the Polling.exe CLI.
3. Check the Wine debug log: `grep -i joystick cross-over-output/wine-debug-*.log`
4. Wine's dinput on macOS may not detect your controller. Try:
   - Connect via USB instead of Bluetooth
   - Install `dxvk` or `winetricks xinput` in the bottle
   - Set `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1` before running
5. If Wine cannot see the controller at all, the delta is `?` — this is useful
   data (it means CrossOver has no gamepad passthrough on macOS).

### Polling.exe crashes on launch
1. Check `wine --version` inside the bottle — must be Wine 9+
2. Try installing `vcrun2022` via CrossOver's bottle settings
3. Fall back to running Polling from Python source inside the bottle

### Native test fails (Stage 1 blocked)
This is expected until the macOS GameController framework input capture is
resolved. The comparison script will run the bottle test anyway and mark the
native column as `?`.

## Technical Details

Both tools use **pygame/SDL2** for controller access:
- **Native**: SDL2 → Apple GameController framework → IOKit HID → DS4/Xbox
- **Bottle**: SDL2 (bundled in PyInstaller) → Wine dinput.dll → macOS HID

They share the same measurement methodology (stick position change detection,
outlier filtering, statistical analysis), so the comparison is apples-to-apples.

## References

- cakama3a/Polling: https://github.com/cakama3a/Polling
- gamepadla-plus (native): WyvernIXTL/gamepadla-plus (in this repo)
- CrossOver CLI docs: https://www.codeweavers.com/support/wiki/linux/faq/cxrun
- WINEDEBUG channels: See `../log-analyzer/wine-debug-channels.md`
