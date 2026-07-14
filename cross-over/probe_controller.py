"""Controller probe for CrossOver/Wine bottle.

Runs inside the bottle via `wine python probe_controller.py`.
Zero external dependencies — uses only ctypes (stdlib) to call XInputGetState.

Exit codes:
  0  = Controller found + live data flowing
  1  = Controller found but no position change detected
  2  = No controller found
  3  = XInput DLL not found
  4  = No Python (detected before execution)
"""

import ctypes
import ctypes.wintypes
import sys
import time

ERROR_SUCCESS = 0
ERROR_DEVICE_NOT_CONNECTED = 1167
ERROR_INVALID_PARAMETER = 87


class XINPUT_GAMEPAD(ctypes.Structure):
    _fields_ = [
        ("wButtons", ctypes.c_uint16),
        ("bLeftTrigger", ctypes.c_uint8),
        ("bRightTrigger", ctypes.c_uint8),
        ("sThumbLX", ctypes.c_int16),
        ("sThumbLY", ctypes.c_int16),
        ("sThumbRX", ctypes.c_int16),
        ("sThumbRY", ctypes.c_int16),
    ]


class XINPUT_STATE(ctypes.Structure):
    _fields_ = [
        ("dwPacketNumber", ctypes.c_uint32),
        ("Gamepad", XINPUT_GAMEPAD),
    ]


def gamepad_to_tuple(g: XINPUT_GAMEPAD):
    return (
        g.wButtons,
        g.bLeftTrigger,
        g.bRightTrigger,
        g.sThumbLX,
        g.sThumbLY,
        g.sThumbRX,
        g.sThumbRY,
    )


def probe_player(dll, player_index: int) -> tuple[int, XINPUT_STATE | None]:
    state = XINPUT_STATE()
    rc = dll.XInputGetState(player_index, ctypes.byref(state))
    if rc == ERROR_SUCCESS:
        return rc, state
    return rc, None


def main():
    try:
        dll = ctypes.windll.xinput1_4
    except AttributeError:
        try:
            dll = ctypes.windll.xinput1_3
        except AttributeError:
            dll = ctypes.windll.xinput9_1_0
        except AttributeError:
            print("XInput DLL not found (tried xinput1_4, xinput1_3, xinput9_1_0)")
            sys.exit(3)

    print(f"XInput DLL: {dll._name}")

    found_players = []
    for i in range(4):
        rc, state = probe_player(dll, i)
        if rc == ERROR_SUCCESS and state is not None:
            found_players.append((i, state))
            print(f"Player {i}: CONNECTED (packet={state.dwPacketNumber})")
            g = state.Gamepad
            print(
                f"  Buttons={g.wButtons:04x} "
                f"LT={g.bLeftTrigger:3d} RT={g.bRightTrigger:3d}  "
                f"LX={g.sThumbLX:+5d} LY={g.sThumbLY:+5d}  "
                f"RX={g.sThumbRX:+5d} RY={g.sThumbRY:+5d}"
            )
        elif rc == ERROR_DEVICE_NOT_CONNECTED:
            pass
        elif rc == ERROR_INVALID_PARAMETER:
            pass

    if not found_players:
        print("No controller found on any player slot (0-3).")
        print()
        print("Possible reasons:")
        print("  1. Controller is not powered on / paired")
        print("  2. Wine's XInput implementation doesn't have a HID passthrough on macOS")
        print("  3. Controller is connected via different protocol (check Bluetooth/USB)")
        sys.exit(2)

    print()
    print(f"Live check: reading Player {found_players[0][0]} twice (500ms apart)...")

    _, first_state = found_players[0]
    first = gamepad_to_tuple(first_state.Gamepad)

    time.sleep(0.5)

    rc, second_state = probe_player(dll, found_players[0][0])
    if rc != ERROR_SUCCESS:
        print("LOST connection during live check — controller was disconnected!")
        sys.exit(1)

    second = gamepad_to_tuple(second_state.Gamepad)

    if first != second:
        print("LIVE: axis/button values changed between reads — data IS flowing.")
        sys.exit(0)
    else:
        print("STALE: values did not change in 0.5s.")
        print("  This could mean:")
        print("  - You did not move the stick or press buttons (normal — the controller")
        print("    only sends reports on physical change, not continuously)")
        print("  - Wine is returning cached/zero values even though the device is present")
        print()
        print("  To distinguish: move the stick and press buttons, then re-run.")
        print("  If values STILL don't change after active movement, Wine's XInput")
        print("  translation may be broken.")
        sys.exit(1)


if __name__ == "__main__":
    main()
