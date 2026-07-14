/*
 * probe_live.c — continuous XInput poller for CrossOver/Wine (in-bottle latency probe)
 *
 * Polls XInputGetState in a tight loop for DURATION_MS, counts how many times the
 * packet number increments and how many times gamepad values change, and records the
 * wall-clock interval between successive packet-number changes to estimate the report
 * cadence the game actually sees THROUGH CrossOver.
 *
 * Compile: x86_64-w64-mingw32-gcc -O2 -o probe_live.exe probe_live.c
 *
 * Exit: 0 = live data seen, 1 = connected but no change, 2 = no controller, 3 = no XInput dll
 */
#include <windows.h>
#include <stdio.h>

#pragma pack(push, 4)
typedef struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger;
                 SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } XINPUT_GAMEPAD;
typedef struct { DWORD dwPacketNumber; XINPUT_GAMEPAD Gamepad; } XINPUT_STATE;
#pragma pack(pop)
typedef DWORD (WINAPI *XIGetState_t)(DWORD, XINPUT_STATE*);

#define DURATION_MS 12000

int main(void) {
    const char *names[] = {"xinput1_4.dll","xinput1_3.dll","xinput9_1_0.dll",NULL};
    HMODULE dll = NULL; XIGetState_t XInputGetState = NULL;
    for (int i = 0; names[i]; i++) {
        dll = LoadLibraryA(names[i]);
        if (dll) { XInputGetState = (XIGetState_t)GetProcAddress(dll,"XInputGetState");
                   if (XInputGetState) { printf("XInput DLL: %s\n", names[i]); break; }
                   FreeLibrary(dll); dll = NULL; }
    }
    if (!XInputGetState) { printf("XInput DLL not found\n"); return 3; }

    /* find first connected slot */
    int slot = -1; XINPUT_STATE s;
    for (int i = 0; i < 4; i++) if (XInputGetState(i,&s) == ERROR_SUCCESS) { slot = i; break; }
    if (slot < 0) { printf("No controller on slots 0-3.\n"); return 2; }
    printf("Controller on slot %d. Polling %d s — MOVE THE LEFT STICK / PRESS BUTTONS NOW...\n",
           slot, DURATION_MS/1000);

    LARGE_INTEGER freq, t0, tnow, tlast_pkt; QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&t0); tlast_pkt = t0;
    DWORD lastPkt = 0; int haveLast = 0;
    long polls = 0, pktChanges = 0;
    double sum_ms = 0, min_ms = 1e9, max_ms = 0; long intervals = 0;
    double last_report_s = 0;

    for (;;) {
        XINPUT_STATE st;
        if (XInputGetState(slot,&st) != ERROR_SUCCESS) { printf("LOST connection.\n"); break; }
        polls++;
        if (!haveLast) { lastPkt = st.dwPacketNumber; haveLast = 1; }
        else if (st.dwPacketNumber != lastPkt) {
            QueryPerformanceCounter(&tnow);
            double dt = (double)(tnow.QuadPart - tlast_pkt.QuadPart) * 1000.0 / freq.QuadPart;
            if (dt > 0 && dt < 500) { sum_ms += dt; intervals++;
                if (dt < min_ms) min_ms = dt; if (dt > max_ms) max_ms = dt; }
            tlast_pkt = tnow; lastPkt = st.dwPacketNumber; pktChanges++;
        }
        QueryPerformanceCounter(&tnow);
        double el = (double)(tnow.QuadPart - t0.QuadPart) / freq.QuadPart;
        if (el - last_report_s >= 1.0) {
            last_report_s = el;
            printf("  t=%4.1fs polls=%ld pktChanges=%ld  LX=%+6d LY=%+6d btn=0x%04x\n",
                   el, polls, pktChanges, st.Gamepad.sThumbLX, st.Gamepad.sThumbLY, st.Gamepad.wButtons);
        }
        if (el * 1000.0 >= DURATION_MS) break;
        Sleep(1); /* ~1000 Hz sampling ceiling */
    }

    printf("\nTOTAL polls=%ld  packet-changes=%ld\n", polls, pktChanges);
    if (intervals > 0) {
        double avg = sum_ms / intervals;
        printf("Report interval (between packet changes): min=%.2f avg=%.2f max=%.2f ms\n",
               min_ms, avg, max_ms);
        printf("Effective in-bottle polling rate ~= %.1f Hz (from avg interval)\n", 1000.0/avg);
        printf("VERDICT: LIVE DATA through CrossOver — SDL backend is delivering input.\n");
        return 0;
    } else {
        printf("VERDICT: connected but ZERO packet changes — no live input reached the game side.\n");
        return 1;
    }
}
