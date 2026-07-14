"""Signal detector patterns for CrossOver/Wine log analysis.

Each detector is a dict with:
    name:     short label
    patterns: list of regex patterns to match
    category: classification (input_path, graphics, system, timing, device)
    relevance: how useful for measuring latency (direct, indirect, none)
    limitation: what this signal CANNOT tell us
"""

DETECTORS = [
    # ── Input Path ───────────────────────────────────────────────────────
    {
        "name": "HID device init",
        "patterns": [
            r"HID", r"hidraw\d+", r"IOHIDDevice", r"IOHIDManager",
            r"IOReturn.*hid", r"kIOHID",
        ],
        "category": "input_path",
        "relevance": "indirect",
        "limitation": (
            "Shows when the controller was detected/enumerated, not polling rate. "
            "Timing between init and first report may indicate device enumeration "
            "overhead, but this is startup-only — not relevant to steady-state latency."
        ),
    },
    {
        "name": "HID report activity",
        "patterns": [
            r"get_report", r"set_report", r"HID.*report",
            r"IOHIDDeviceGetReport", r"IOHIDDeviceSetReport",
        ],
        "category": "input_path",
        "relevance": "indirect",
        "limitation": (
            "HID-level report arrivals. If timestamped, can compute report intervals. "
            "However, this is OS-level HID, not game-level — reports may be buffered, "
            "merged, or dropped before reaching the game's input polling loop."
        ),
    },
    {
        "name": "dinput device detection",
        "patterns": [
            r"IDirectInput(8)?(Device)?", r"DirectInput.*Create",
            r"EnumDevices", r"dinput.*device", r"SetCooperativeLevel",
            r"SetDataFormat", r"Acquire", r"Unacquire",
        ],
        "category": "input_path",
        "relevance": "indirect",
        "limitation": (
            "Shows Wine's DirectInput device lifecycle (create, acquire, release). "
            "Device acquisition/unacquisition timing is useful for detecting context "
            "switches or focus loss, but doesn't measure per-report latency."
        ),
    },
    {
        "name": "dinput polling / GetDeviceState",
        "patterns": [
            r"GetDeviceState", r"Poll.*device", r"dinput.*GetData",
            r"GetDeviceData",
        ],
        "category": "input_path",
        "relevance": "direct",
        "limitation": (
            "This is the closest we get to 'what the game sees.' GetDeviceState is "
            "what games call to read the controller. If timestamped, the interval "
            "between successive GetDeviceState calls approximates the game's polling "
            "rate. BUT: (1) this is the game's poll, not the hardware's report rate; "
            "(2) Wine may cache/return stale data without a real HID read; "
            "(3) no information about when the physical report actually arrived."
        ),
    },
    {
        "name": "XInput calls",
        "patterns": [
            r"XInputGetState", r"XInputSetState", r"XINPUT_STATE",
            r"XInputEnable", r"XInputGetCapabilities",
        ],
        "category": "input_path",
        "relevance": "direct",
        "limitation": (
            "XInput is the Windows API most Xbox-controller games use. "
            "XInputGetState calls with timestamps show game polling rate. "
            "Same caveat as GetDeviceState: polling rate != true latency. "
            "XInput on Wine may be implemented on top of dinput or HID, "
            "adding its own translation layer."
        ),
    },
    {
        "name": "SDL joystick events",
        "patterns": [
            r"SDL_Joystick(Open|Close|Update|GetAxis|GetButton)",
            r"JOYSTICK", r"joystick.*event",
            r"SDL_CONTROLLER", r"SDL_GameController",
        ],
        "category": "input_path",
        "relevance": "indirect",
        "limitation": (
            "SDL-level joystick events. SDL is a middleware layer between the OS and "
            "the game. These events are one step further from hardware than dinput. "
            "Useful for seeing if SDL detected the controller and what mapping it used."
        ),
    },

    # ── Graphics Pipeline ─────────────────────────────────────────────────
    {
        "name": "Direct3D / D3DMetal frame timing",
        "patterns": [
            r"D3D.*Present", r"d3d11.*Present", r"d3d.*SwapChain",
            r"D3DMetal", r"MTLCommandBuffer", r"MTLDrawable",
            r"CAMetalLayer", r"nextDrawable",
        ],
        "category": "graphics",
        "relevance": "direct",
        "limitation": (
            "Present/swap marks the END of the GPU pipeline for a frame. "
            "This gives frame boundaries and frame pacing. BUT: Present is the "
            "last step — it tells you nothing about when input was sampled, "
            "how long the CPU simulation took, or GPU render queue depth. "
            "At best, it's a timestamp for the 'photon' end of button-to-photon."
        ),
    },
    {
        "name": "VSync / swap interval",
        "patterns": [
            r"vsync", r"swap.interval", r"V-SYNC", r"vertical.sync",
            r"present.interval", r"SyncInterval",
        ],
        "category": "graphics",
        "relevance": "indirect",
        "limitation": (
            "VSync configuration — tells you the display refresh target. "
            "Not a latency measurement, but relevant context: if VSync is on, "
            "there's at least 1 frame (16.67ms at 60Hz) of added latency from "
            "the swapchain queue alone. VSync off may tear but reduces this."
        ),
    },
    {
        "name": "DXVK frame timing",
        "patterns": [
            r"DXVK", r"dxvk.*present", r"vkQueuePresent",
            r"VkPresent", r"vkAcquireNextImage",
        ],
        "category": "graphics",
        "relevance": "direct",
        "limitation": (
            "DXVK's Vulkan present/acquire timing. Same frame-boundary utility "
            "as D3DMetal, but through the Vulkan translation layer. "
            "vkAcquireNextImage → game renders → vkQueuePresent: the gap between "
            "acquire and present is GPU frame time."
        ),
    },

    # ── Timing / Performance ──────────────────────────────────────────────
    {
        "name": "FPS / frametime lines",
        "patterns": [
            r"\b[Ff][Pp][Ss]\b", r"\bframetime\b", r"\bframe_time\b",
            r"\bms/frame\b", r"\bframe.*\d+\.?\d*\s*ms",
        ],
        "category": "timing",
        "relevance": "indirect",
        "limitation": (
            "Engine-reported FPS or frametime. This is the game's own measurement, "
            "which may be: (1) smoothed/averaged, (2) measured at a different point "
            "in the pipeline than input sampling, (3) affected by the measurement "
            "overhead itself. NOT a latency measurement — it tells you frame pacing, "
            "not when input arrived relative to frames."
        ),
    },
    {
        "name": "Wine timestamp prefix",
        "patterns": [
            r"^\d{4,6}\.\d{3,6}:",
            r"trace:.*:\d+\.\d{3,6}:",
        ],
        "category": "timing",
        "relevance": "indirect",
        "limitation": (
            "Wine's built-in timestamp prefix (from +timestamp channel). "
            "These are Wine's internal clock, not wall-clock. Small discrepancies "
            "with real time are possible. Useful for computing intervals between "
            "Wine-internal events but cannot be directly compared to external "
            "measurements."
        ),
    },

    # ── System / Connection ───────────────────────────────────────────────
    {
        "name": "USB / Bluetooth events",
        "patterns": [
            r"bluetooth", r"\bBT\b.*disconnect", r"\bUSB\b.*disconnect",
            r"reconnect", r"connection.*lost", r"device.*removed",
            r"device.*added", r"plug.*in|out",
        ],
        "category": "system",
        "relevance": "indirect",
        "limitation": (
            "Physical connection state changes. A disconnect/reconnect event means "
            "the controller was briefly gone — this explains outlier latency spikes "
            "but doesn't measure latency itself. Count these as artifacts."
        ),
    },
    {
        "name": "Controller device enumeration",
        "patterns": [
            r"add_device", r"remove_device", r"device.*enum",
            r"Plug and Play", r"PnP.*device", r"SetupDi",
        ],
        "category": "system",
        "relevance": "none",
        "limitation": (
            "Windows device enumeration events. Shows when Wine discovered a device. "
            "Not latency-relevant — this is device lifecycle, not input timing."
        ),
    },

    # ── Warnings / Errors ─────────────────────────────────────────────────
    {
        "name": "Thread / scheduler warnings",
        "patterns": [
            r"thread.*warn", r"sched.*warn", r"fixme:ntdll",
            r"RtlSetThread", r"SetThread", r"thread.*priority",
            r"wine.*thread", r"err:ntdll",
        ],
        "category": "system",
        "relevance": "indirect",
        "limitation": (
            "Thread/scheduler warnings suggest potential jitter sources — "
            "if the input thread is being descheduled, input timing suffers. "
            "BUT: these are circumstantial. A warning doesn't prove latency "
            "actually occurred, and the absence of warnings doesn't prove "
            "smooth scheduling."
        ),
    },
    {
        "name": "DLL load / stub warnings",
        "patterns": [
            r"fixme:.*stub", r"warn:.*dll", r"err:module",
            r"Native DLL", r"builtin.*dll",
        ],
        "category": "system",
        "relevance": "none",
        "limitation": (
            "DLL load and stub warnings. These indicate missing or incomplete Wine "
            "implementations that might affect functionality but are not latency "
            "measurements. A missing DLL could mean input goes through a different "
            "code path, but you can't quantify latency from these messages."
        ),
    },
]


def detector_summary() -> list[dict]:
    """Return detectors grouped by category for display."""
    return DETECTORS


CATEGORY_LABELS = {
    "input_path": "Input Path (Controller -> Game)",
    "graphics":   "Graphics Pipeline (GPU -> Display)",
    "timing":     "Timing / Performance",
    "system":     "System / Connection / Warnings",
    "device":     "Device Enumeration",
}
