/*
 * probe_controller.c — standalone XInput controller probe for CrossOver/Wine
 *
 * Compile: x86_64-w64-mingw32-gcc -O2 -o probe_controller.exe probe_controller.c
 *
 * Exit codes:
 *   0 = controller found + live data flowing
 *   1 = controller found but no position change detected
 *   2 = no controller found on any player slot
 *   3 = XInput DLL not found
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

/* XINPUT_STATE structure (from XInput.h) */
#pragma pack(push, 4)
typedef struct {
    WORD  wButtons;
    BYTE  bLeftTrigger;
    BYTE  bRightTrigger;
    SHORT sThumbLX;
    SHORT sThumbLY;
    SHORT sThumbRX;
    SHORT sThumbRY;
} XINPUT_GAMEPAD;

typedef struct {
    DWORD          dwPacketNumber;
    XINPUT_GAMEPAD Gamepad;
} XINPUT_STATE;
#pragma pack(pop)

/* XInput function pointer type */
typedef DWORD (WINAPI *XIGetState_t)(DWORD, XINPUT_STATE*);

/* Return codes */
#define RC_LIVE      0
#define RC_STALE     1
#define RC_NOT_FOUND 2
#define RC_NO_DLL    3

int probe_player(XIGetState_t XInputGetState, int player, XINPUT_STATE *state) {
    return XInputGetState((DWORD)player, state);
}

void print_gamepad(int player, const XINPUT_STATE *state) {
    const XINPUT_GAMEPAD *g = &state->Gamepad;
    printf("Player %d: CONNECTED (packet=%lu)\n", player, (unsigned long)state->dwPacketNumber);
    printf("  Buttons=0x%04x LT=%3d RT=%3d  "
           "LX=%+5d LY=%+5d  RX=%+5d RY=%+5d\n",
           g->wButtons,
           (int)g->bLeftTrigger, (int)g->bRightTrigger,
           (int)g->sThumbLX, (int)g->sThumbLY,
           (int)g->sThumbRX, (int)g->sThumbRY);
}

int gamepad_equal(const XINPUT_GAMEPAD *a, const XINPUT_GAMEPAD *b) {
    return a->wButtons == b->wButtons
        && a->bLeftTrigger == b->bLeftTrigger
        && a->bRightTrigger == b->bRightTrigger
        && a->sThumbLX == b->sThumbLX
        && a->sThumbLY == b->sThumbLY
        && a->sThumbRX == b->sThumbRX
        && a->sThumbRY == b->sThumbRY;
}

int main(void) {
    HMODULE      dll = NULL;
    XIGetState_t XInputGetState = NULL;
    const char  *dll_names[] = {
        "xinput1_4.dll",
        "xinput1_3.dll",
        "xinput9_1_0.dll",
        NULL
    };

    /* Try each XInput DLL */
    for (int i = 0; dll_names[i] != NULL; i++) {
        dll = LoadLibraryA(dll_names[i]);
        if (dll) {
            XInputGetState = (XIGetState_t)GetProcAddress(dll, "XInputGetState");
            if (XInputGetState) {
                printf("XInput DLL: %s\n", dll_names[i]);
                break;
            }
            FreeLibrary(dll);
            dll = NULL;
        }
    }

    if (!dll || !XInputGetState) {
        printf("XInput DLL not found (tried xinput1_4, xinput1_3, xinput9_1_0)\n");
        return RC_NO_DLL;
    }

    /* Probe all 4 player slots */
    int found = 0;
    int first_player = -1;
    XINPUT_STATE first_state;

    for (int i = 0; i < 4; i++) {
        XINPUT_STATE state;
        DWORD rc = probe_player(XInputGetState, i, &state);

        if (rc == ERROR_SUCCESS) {
            print_gamepad(i, &state);
            if (!found) {
                first_state = state;
                first_player = i;
            }
            found++;
        }
    }

    if (!found) {
        printf("\nNo controller found on any player slot (0-3).\n");
        printf("\n");
        printf("Possible reasons:\n");
        printf("  1. Controller is not powered on / paired\n");
        printf("  2. Wine's XInput implementation doesn't have a HID passthrough on macOS\n");
        printf("  3. Controller is connected via different protocol (check Bluetooth/USB)\n");
        FreeLibrary(dll);
        return RC_NOT_FOUND;
    }

    /* Live check: read twice with 500ms gap */
    printf("\nLive check: reading Player %d twice (500ms apart)...\n", first_player);
    Sleep(500);

    XINPUT_STATE second_state;
    DWORD rc = probe_player(XInputGetState, first_player, &second_state);

    if (rc != ERROR_SUCCESS) {
        printf("LOST connection during live check — controller was disconnected!\n");
        FreeLibrary(dll);
        return RC_STALE;
    }

    if (!gamepad_equal(&first_state.Gamepad, &second_state.Gamepad)) {
        printf("LIVE: axis/button values changed between reads — data IS flowing.\n");
        FreeLibrary(dll);
        return RC_LIVE;
    } else {
        printf("STALE: values did not change in 0.5s.\n");
        printf("  This could mean:\n");
        printf("  - You did not move the stick or press buttons (normal — the controller\n");
        printf("    only sends reports on physical change, not continuously)\n");
        printf("  - Wine is returning cached/zero values even though the device is present\n");
        printf("\n");
        printf("  To distinguish: move the stick and press buttons, then re-run.\n");
        printf("  If values STILL don't change after active movement, Wine's XInput\n");
        printf("  translation may be broken.\n");
        FreeLibrary(dll);
        return RC_STALE;
    }
}
