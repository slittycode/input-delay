# CrossOver / Wine Log Analysis: Latency Signals

> Generated: 2026-07-14 23:34:51
> Logs directory: `logs`

## Files Analyzed (1)

- `Elden Ring Test.cxlog` (5000.2 KB)

## Elden Ring Test.cxlog
Format: `crossover_app` | Findings: 9

### Graphics Pipeline (GPU -> Display)

#### Finding: Direct3D / D3DMetal frame timing [DIRECT]
- **Matches**: 14 lines
- **Line range**: 12–43807

**Sample matches:**
```
  L12: Graphics: D3DMetal
  L79: WINED3DMETAL -> 1
  L80: CX_GRAPHICS_BACKEND -> d3dmetal
  L184: 12940.062:0028:002c:trace:process:set_graphics_backend using d3dmetal as the graphics backend
  L3441: 12940.212:0030:0034:trace:process:set_graphics_backend using d3dmetal as the graphics backend
```

**What this tells us:** Direct3D / D3DMetal frame timing

**Latency relevance:** direct

**Limitation:** Present/swap marks the END of the GPU pipeline for a frame. This gives frame boundaries and frame pacing. BUT: Present is the last step — it tells you nothing about when input was sampled, how long the CPU simulation took, or GPU render queue depth. At best, it's a timestamp for the 'photon' end of button-to-photon.

### Input Path (Controller -> Game)

#### Finding: HID device init [indirect]
- **Matches**: 125 lines
- **Line range**: 6691–49753

**Sample matches:**
```
  L6691: 12940.266:0030:0034:trace:process:ExpandEnvironmentStringsW (L"C:\\windows\\system32\\drivers\\winehid.sys" 0000000000000000 0)
  L6692: 12940.266:0030:0034:trace:process:ExpandEnvironmentStringsW (L"C:\\windows\\system32\\drivers\\winehid.sys" 000000000003DD20 40)
  L21917: 12940.804:0090:009c:trace:module:load_dll looking for L"hidparse.sys" in L"C:\\windows\\system32\\drivers;C:\\windows\\system32;C:\\windows\\system32\\drivers;C:\\windows\\system32\\"
  L21918: 12940.804:0090:009c:trace:file:RtlDosPathNameToNtPathName_U_WithStatus (L"C:\\windows\\system32\\drivers\\hidparse.sys",0000000000A1F080,0000000000000000,0000000000000000)
  L21919: 12940.804:0090:009c:trace:file:RtlGetFullPathName_U (L"C:\\windows\\system32\\drivers\\hidparse.sys" 520 0000000000A1EBB0 0000000000000000)
```

**What this tells us:** HID device init

**Latency relevance:** indirect

**Limitation:** Shows when the controller was detected/enumerated, not polling rate. Timing between init and first report may indicate device enumeration overhead, but this is startup-only — not relevant to steady-state latency.

#### Finding: XInput calls [DIRECT]
- **Matches**: 5 lines
- **Line range**: 48277–48815

**Sample matches:**
```
  L48277: 12942.609:00d4:00d8:trace:xinput:XInputGetState index 0, state 000000000031FE40.
  L48774: 12942.694:00d4:00d8:trace:xinput:XInputGetState index 1, state 000000000031FE40.
  L48775: 12942.694:00d4:00d8:trace:xinput:XInputGetState index 2, state 000000000031FE40.
  L48776: 12942.694:00d4:00d8:trace:xinput:XInputGetState index 3, state 000000000031FE40.
  L48815: 12943.195:00d4:00d8:trace:xinput:XInputGetState index 0, state 000000000031FE40.
```

**What this tells us:** XInput calls

**Latency relevance:** direct

**Limitation:** XInput is the Windows API most Xbox-controller games use. XInputGetState calls with timestamps show game polling rate. Same caveat as GetDeviceState: polling rate != true latency. XInput on Wine may be implemented on top of dinput or HID, adding its own translation layer.

#### Finding: SDL joystick events [indirect]
- **Matches**: 8 lines
- **Line range**: 3–38308

**Sample matches:**
```
  L3: Debug channels: +file,+ntdll,+dinput,+joystick,+winmm,+xinput,+event,+win,+macdrv
  L97: WINEDEBUG = "+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+event,+win,+macdrv"
  L100: CX_DEBUGMSG = "+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+event,+win,+macdrv"
  L134: 12940.033:0020:0024:trace:process:send_to_cx_loader wineserversocket 7 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug "WINEDEBUG=+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+even
  L3393: 12940.183:0028:002c:trace:process:send_to_cx_loader wineserversocket 14 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug "WINEDEBUG=+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+eve
```

**What this tells us:** SDL joystick events

**Latency relevance:** indirect

**Limitation:** SDL-level joystick events. SDL is a middleware layer between the OS and the game. These events are one step further from hardware than dinput. Useful for seeing if SDL detected the controller and what mapping it used.

### System / Connection / Warnings

#### Finding: USB / Bluetooth events [indirect]
- **Matches**: 42 lines
- **Line range**: 120–48678

**Sample matches:**
```
  L120: output=[]
  L134: 12940.033:0020:0024:trace:process:send_to_cx_loader wineserversocket 7 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug "WINEDEBUG=+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+even
  L3393: 12940.183:0028:002c:trace:process:send_to_cx_loader wineserversocket 14 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug "WINEDEBUG=+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+eve
  L6818: 12940.278:0030:0034:trace:process:send_to_cx_loader wineserversocket 11 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug (null)
  L10454: 12940.374:0030:0034:trace:process:find_exe_file looking for L"C:\\windows\\system32\\plugplay.exe" in L"C:\\windows\\system32;.;C:\\windows\\system32;C:\\windows\\system;C:\\windows;C:\\windows\\system32;C:\\windows;C:\\windows\\system32\\wbem;C:\\wi
```

**What this tells us:** USB / Bluetooth events

**Latency relevance:** indirect

**Limitation:** Physical connection state changes. A disconnect/reconnect event means the controller was briefly gone — this explains outlier latency spikes but doesn't measure latency itself. Count these as artifacts.

#### Finding: Controller device enumeration [NONE]
- **Matches**: 30 lines
- **Line range**: 23323–23818

**Sample matches:**
```
  L23323: 12941.062:0090:00a4:trace:xinput:add_device driver 0000000000A2ACD0, bus_device 0000000000A632B0.
  L23327: 12941.062:0090:00a4:trace:xinput:add_device device 0000000000A66460, bus_id L"WINEBUS", device_id L"WINEXINPUT\\VID_045E&PID_0B13", instance_id L"1599&0000ffffffff0b13045e&0&0&1".
  L23330: 12941.062:0090:00a4:trace:xinput:fdo_pnp device 0000000000A66460, irp 00000000008018A0, code 0, bus_device 0000000000A632B0.
  L23346: 12941.063:0090:00a4:trace:xinput:fdo_pnp device 0000000000A66460, irp 00000000008018A0, code 0x13, bus_device 0000000000A632B0.
  L23347: 12941.063:0090:00a4:trace:xinput:fdo_pnp device 0000000000A66460, irp 00000000008018A0, code 0x13, bus_device 0000000000A632B0.
```

**What this tells us:** Controller device enumeration

**Latency relevance:** none

**Limitation:** Windows device enumeration events. Shows when Wine discovered a device. Not latency-relevant — this is device lifecycle, not input timing.

#### Finding: Thread / scheduler warnings [indirect]
- **Matches**: 15 lines
- **Line range**: 97–50128

**Sample matches:**
```
  L97: WINEDEBUG = "+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+event,+win,+macdrv"
  L134: 12940.033:0020:0024:trace:process:send_to_cx_loader wineserversocket 7 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug "WINEDEBUG=+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+even
  L3393: 12940.183:0028:002c:trace:process:send_to_cx_loader wineserversocket 14 stdin_fd -1 stdout_fd -1 unixdir (null) winedebug "WINEDEBUG=+timestamp,+pid,+seh,+unwind,+process,+module,+loaddll,+threadname,+file,+ntdll,+dinput,+joystick,+winmm,+xinput,+eve
  L10160: 12940.355:0030:0048:warn:threadname:NtSetInformationThread Thread renamed to L"wine_threadpool_worker"
  L23020: 12940.981:0060:00b8:warn:threadname:NtSetInformationThread Thread renamed to L"wine_threadpool_worker"
```

**What this tells us:** Thread / scheduler warnings

**Latency relevance:** indirect

**Limitation:** Thread/scheduler warnings suggest potential jitter sources — if the input thread is being descheduled, input timing suffers. BUT: these are circumstantial. A warning doesn't prove latency actually occurred, and the absence of warnings doesn't prove smooth scheduling.

#### Finding: DLL load / stub warnings [NONE]
- **Matches**: 264 lines
- **Line range**: 141–48511

**Sample matches:**
```
  L141: 12940.060:0028:002c:trace:module:find_builtin_dll looking for "wineboot.exe" for file L"\\??\\C:\\windows\\system32\\wineboot.exe"
  L216: 12940.075:0028:002c:trace:module:find_builtin_dll looking for "kernel32.dll" for file L"\\??\\C:\\windows\\system32\\kernel32.dll"
  L247: 12940.077:0028:002c:trace:module:find_builtin_dll looking for "kernelbase.dll" for file L"\\??\\C:\\windows\\system32\\kernelbase.dll"
  L326: 12940.083:0028:002c:trace:module:find_builtin_dll looking for "advapi32.dll" for file L"\\??\\C:\\windows\\system32\\advapi32.dll"
  L362: 12940.084:0028:002c:trace:module:find_builtin_dll looking for "msvcrt.dll" for file L"\\??\\C:\\windows\\system32\\msvcrt.dll"
```

**What this tells us:** DLL load / stub warnings

**Latency relevance:** none

**Limitation:** DLL load and stub warnings. These indicate missing or incomplete Wine implementations that might affect functionality but are not latency measurements. A missing DLL could mean input goes through a different code path, but you can't quantify latency from these messages.

### Timing / Performance

#### Finding: Wine timestamp prefix [indirect]
- **Matches**: 50025 lines
- **Line range**: 125–50164

**Sample matches:**
```
  L125: 12940.031:0020:0024:trace:ntdll:NtQueryInformationToken (0xfffffffffffffffa,TokenUser,0x7ff206556d00,80,0x7ff206556da4)
  L126: 12940.032:0020:0024:trace:ntdll:NtQueryInformationToken (0xfffffffffffffffa,TokenUser,0x7ff206556780,80,0x7ff206556824)
  L127: 12940.032:0020:0024:trace:ntdll:NtQueryInformationToken (0xfffffffffffffffa,TokenUser,0x7ff206556780,80,0x7ff206556824)
  L128: 12940.033:0020:0024:trace:ntdll:init_xstate_features XSAVE details 0x7, 0x340, 0x340, 0.
  L129: 12940.033:0020:0024:trace:ntdll:init_xstate_features xstate[2] offset 240, size 100, aligned 0.
```

**What this tells us:** Wine timestamp prefix

**Latency relevance:** indirect

**Limitation:** Wine's built-in timestamp prefix (from +timestamp channel). These are Wine's internal clock, not wall-clock. Small discrepancies with real time are possible. Useful for computing intervals between Wine-internal events but cannot be directly compared to external measurements.

---

## Summary: What These Logs Can and Cannot Tell Us

### What CAN be determined from these logs

1. **Controller detection timing** — when the controller was first detected by Wine/HID. Useful for measuring initialization overhead.

3. **Frame boundaries** — Present/swap timestamps mark the GPU end of each frame, giving frame pacing data. Combined with input polling rate, this gives an upper bound on input latency (must be > 1 game frame).

5. **Connection stability** — disconnect/reconnect events identify blips that would cause outlier latency spikes.

### What CANNOT be determined (requires Stage 2)

1. **True button-to-photon latency** — the time between a physical button press and the corresponding change in screen pixels. This requires a high-speed camera or hardware latency tester (e.g., LDAT, OSRTT).

2. **CrossOver input translation overhead** — the delay Wine adds between the macOS HID layer and the Windows game's XInput/dinput API. Requires the native vs in-bottle comparison (Addition A).

3. **macOS input stack latency** — the delay between the Bluetooth radio receiving a controller packet and it reaching the IOKit HID layer. Requires kernel-level tracing or a hardware USB analyzer.

4. **Display latency** — pixel response time, scanout rate, and any compositor buffering. Requires a photodiode or high-speed camera at the display.

5. **Input-to-render pipeline depth** — how many frames of buffering exist between the game reading input and that input affecting rendered output. This varies by game engine and render pipeline configuration.

### Recommendations for Better Data

To get more actionable signals from Wine logs, enable these WINEDEBUG channels:

```bash
# Input path with timestamps:
WINEDEBUG=+timestamp,+dinput,+hid,+xinput wine game.exe 2> input-trace.log

# Graphics pipeline with timestamps:
WINEDEBUG=+timestamp,+d3d,+d3d11,+dxgi wine game.exe 2> gpu-trace.log

# Full diagnostics (huge output — use for 10-30 second captures):
WINEDEBUG=+timestamp,+dinput,+hid,+xinput,+d3d,+d3d11,+dxgi,+seh wine game.exe 2> full.log
```

See `log-analyzer/wine-debug-channels.md` for all available channels.