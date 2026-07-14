# WINEDEBUG Channels Reference

Wine debug channels relevant to controller input latency analysis.

## How to Use

```bash
# Set for one command:
WINEDEBUG=+channel1,+channel2 wine program.exe 2> debug.log

# Set permanently in a bottle registry:
wine reg add "HKEY_CURRENT_USER\\Software\\Wine\\Debug" \
    /v DebugChannels /t REG_SZ /d "+timestamp,+dinput,+hid" /f
```

Prefix channels with `+` to enable, `-` to disable. Use `+timestamp` for
microsecond-precision timestamps on every debug message.

## Input Path Channels

| Channel | What It Traces | Latency Relevance | Notes |
|---------|---------------|-------------------|-------|
| `+hid` | HID device enumeration, report reads/writes, hidraw | **High** — shows physical report arrival timing | Can produce enormous output with high-polling-rate devices |
| `+dinput` | DirectInput device creation, enumeration, SetCooperativeLevel, GetDeviceState, Acquire/Unacquire | **High** — shows when the game reads controller state | The closest Wine trace to "what the game sees" |
| `+xinput` | XInputGetState, XInputSetState, XInputGetCapabilities | **High** — Xbox controller API calls | Most modern games use XInput, not raw dinput |
| `+joystick` | Wine's joystick driver (legacy, pre-dinput) | **Low** — legacy API, rarely used by modern games | Only relevant for old Win32 joystick API games |
| `+plugplay` | Plug and Play device enumeration | **Indirect** — shows device add/remove timing | Useful for detecting reconnects |

## Graphics Pipeline Channels

| Channel | What It Traces | Latency Relevance | Notes |
|---------|---------------|-------------------|-------|
| `+d3d` | Direct3D core (device creation, surface management) | **Indirect** — init overhead | Not frame-level |
| `+d3d11` | Direct3D 11 draw calls, resource binding, state changes | **Medium** — shows GPU work submission | Enormous output; filter by function |
| `+dxgi` | DXGI swapchain, Present, frame pacing | **High** — frame boundary markers | Present calls are the "photon" end marker |
| `+d3d9` | Direct3D 9 (older games) | **Indirect** — older API | Same role as d3d11 for D3D9 games |
| `+vulkan` | Vulkan device, swapchain, queue operations | **High** — if using DXVK or VKD3D | vkQueuePresent marks frame boundaries |
| `+opengl` | OpenGL context, swap buffers | **Medium** — for OpenGL games | wglSwapBuffers marks frame boundaries |

## Timing / System Channels

| Channel | What It Traces | Latency Relevance | Notes |
|---------|---------------|-------------------|-------|
| `+timestamp` | Adds `timestamp:channel:` prefix to all debug output | **Essential** — enables interval computation | Always include this; without it debug lines can't be ordered or timed |
| `+seh` | Structured exception handling | **Indirect** — shows crashes/stalls | Exception handling overhead can cause frame spikes |
| `+ntdll` | NT kernel calls, thread creation, synchronization | **Indirect** — thread scheduling issues | `fixme:ntdll` messages may indicate scheduling jitter |
| `+thread` | Thread creation/termination | **Low** | Too coarse for latency measurement |
| `+synchronization` | Mutex, semaphore, critical section | **Indirect** — lock contention can cause jitter | Very noisy |
| `+msg` | Windows message queue (PeekMessage, GetMessage) | **Low** — input messages may appear here | Legacy Win32 message-based input only |

## Channel Combinations for Specific Questions

### "Is the controller even visible inside Wine?"
```bash
WINEDEBUG=+timestamp,+dinput,+hid,+plugplay wine Polling.exe 2> detect.log
```
Look for: `hidraw` device enumeration, `IDirectInput8::EnumDevices`, your controller's VID/PID.

### "What's the game's actual polling rate?"
```bash
WINEDEBUG=+timestamp,+dinput,+xinput wine game.exe 2> polling.log
```
Look for: interval between successive `GetDeviceState` or `XInputGetState` calls.
Compute: `1 / avg_interval_seconds = polling_rate_hz`.

### "What's the frame pacing inside the bottle?"
```bash
WINEDEBUG=+timestamp,+dxgi,+d3d11 wine game.exe 2> frames.log
```
Look for: interval between successive `Present` calls. Compute frametime stats.

### "Full latency path trace" (only for 10-30 second captures!)
```bash
WINEDEBUG=+timestamp,+dinput,+xinput,+hid,+dxgi,+d3d11 wine game.exe 2> full-trace.log
```
Can correlate input poll timestamps with frame Present timestamps to estimate
maximum input latency (must be > 1 frame, but exact delay unknown without
knowing which frame used which input).

## CrossOver-Specific Notes

- CrossOver uses its own Wine build; some channels may differ from upstream Wine.
- CrossOver's D3DMetal logs go to stderr by default; enable with environment
  variable `MTL_SHADER_VALIDATION=1` for Metal-level tracing.
- CrossOver app-level logs are at `~/Library/Application Support/CrossOver/Logs/`
  and are NOT affected by WINEDEBUG — they're CrossOver-specific, not Wine.
- For DXVK in CrossOver, set `DXVK_LOG_LEVEL=debug` and `DXVK_CONFIG=dxvk.conf`
  in addition to WINEDEBUG.

## Output Volume Warning

A 60-second game session with `+timestamp,+dinput,+xinput,+hid,+dxgi` can
produce 100MB+ of debug output. For initial analysis:
1. Start with just `+dinput,+xinput` (input path only)
2. Add `+dxgi` if frame timing is needed
3. Add `+hid` only if you need hardware-level report timing
4. Always include `+timestamp`
