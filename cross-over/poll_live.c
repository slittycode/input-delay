/*
 * poll_live.c — LIVE in-bottle XInput polling dashboard for CrossOver/Wine.
 *
 * Matches the native PollrateWindow: continuous live display, rolling-window rate,
 * per-device tracking, JSON on close.
 *
 * Compile: x86_64-w64-mingw32-gcc -O2 -mwindows -o poll_live.exe poll_live.c
 * Run:     ./run-poll-live.sh
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#pragma pack(push, 4)
typedef struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger;
                 SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } XINPUT_GAMEPAD;
typedef struct { DWORD dwPacketNumber; XINPUT_GAMEPAD Gamepad; } XINPUT_STATE;
typedef struct {
    BYTE Type, SubType; WORD Flags;
    XINPUT_GAMEPAD Gamepad;
    /* v1.4 cap struct truncated — we only need SubType */
    BYTE vCaps[20];
} XINPUT_CAPABILITIES;
#pragma pack(pop)
typedef DWORD (WINAPI *XIGetState_t)(DWORD, XINPUT_STATE*);
typedef DWORD (WINAPI *XIGetCaps_t)(DWORD, DWORD, XINPUT_CAPABILITIES*);

#define MAX_INTERVALS 4096
#define ROLLING_WINDOW 64

static volatile LONG g_polls = 0, g_pkt_changes = 0, g_slot = -1, g_done = 0;
static volatile LONG g_lx = 0, g_ly = 0; static volatile DWORD g_btn = 0;
static volatile DWORD g_ctype = 0; /* XInput subtype */
static char g_cname[64] = "unknown";
static double g_intervals[MAX_INTERVALS]; static volatile LONG g_icount = 0;
static LARGE_INTEGER g_qpf;

static XIGetState_t XInputGetState = NULL;

static const char *controller_name(DWORD type, DWORD subtype)
{
    switch (subtype) {
    case 1: return "Xbox Gamepad";
    case 2: return "Xbox Wheel";
    case 3: return "Xbox Arcade Stick";
    case 4: return "Xbox Flight Stick";
    case 5: return "Xbox Dance Pad";
    case 6: return "Xbox Guitar";
    case 7: return "Xbox Drum Kit";
    case 9: return "Xbox One Controller";
    case 11: return "Xbox Series X/S";
    default: return "Gamepad";
    }
}

static int cmp_double(const void *a, const void *b)
{
    double d = *(const double *)a - *(const double *)b;
    return d < 0 ? -1 : d > 0 ? 1 : 0;
}

static double percentile(double *sorted, int n, double p)
{
    if (n <= 0) return 0;
    int idx = (int)((double)n * p);
    if (idx >= n) idx = n - 1;
    return sorted[idx];
}

static double avg_d(double *xs, int n)
{
    if (n <= 0) return 0;
    double sum = 0;
    for (int i = 0; i < n; i++) sum += xs[i];
    return sum / n;
}

static double stddev_d(double *xs, int n)
{
    if (n <= 1) return 0;
    double m = avg_d(xs, n);
    double sum = 0;
    for (int i = 0; i < n; i++) { double d = xs[i] - m; sum += d * d; }
    return sqrt(sum / (n - 1));
}

static double min_d(double *xs, int n)
{
    if (n <= 0) return 0;
    double v = xs[0];
    for (int i = 1; i < n; i++) if (xs[i] < v) v = xs[i];
    return v;
}

static double max_d(double *xs, int n)
{
    if (n <= 0) return 0;
    double v = xs[0];
    for (int i = 1; i < n; i++) if (xs[i] > v) v = xs[i];
    return v;
}

DWORD WINAPI poll_thread(LPVOID p)
{
    LARGE_INTEGER t0, tn, tl;
    QueryPerformanceCounter(&t0); tl = t0;

    XINPUT_STATE s; int slot = -1;
    for (int i = 0; i < 4; i++) {
        if (XInputGetState(i, &s) == ERROR_SUCCESS) { slot = i; break; }
    }
    g_slot = slot;
    if (slot < 0) { g_done = -1; return 0; }

    /* get subtype for controller name */
    XIGetCaps_t XIGetCaps = NULL;
    HMODULE dll = GetModuleHandleA("xinput1_4.dll");
    if (!dll) dll = GetModuleHandleA("xinput1_3.dll");
    if (!dll) dll = GetModuleHandleA("xinput9_1_0.dll");
    if (dll) XIGetCaps = (XIGetCaps_t)GetProcAddress(dll, "XInputGetCapabilities");
    if (XIGetCaps) {
        XINPUT_CAPABILITIES caps = {0};
        if (XIGetCaps(slot, 0, &caps) == ERROR_SUCCESS) {
            g_ctype = caps.SubType;
            snprintf(g_cname, sizeof g_cname, "%s", controller_name(0, caps.SubType));
        }
    }

    DWORD lastPkt = 0; int have = 0;
    for (;;) {
        XINPUT_STATE st;
        if (XInputGetState(slot, &st) != ERROR_SUCCESS) break;
        InterlockedIncrement(&g_polls);
        g_lx = st.Gamepad.sThumbLX; g_ly = st.Gamepad.sThumbLY;
        g_btn = st.Gamepad.wButtons;
        if (!have) { lastPkt = st.dwPacketNumber; have = 1; }
        else if (st.dwPacketNumber != lastPkt) {
            QueryPerformanceCounter(&tn);
            double dt = (double)(tn.QuadPart - tl.QuadPart) * 1000.0 / g_qpf.QuadPart;
            if (dt > 0 && dt < 500) {
                LONG i = InterlockedIncrement(&g_icount) - 1;
                if (i < MAX_INTERVALS) g_intervals[i] = dt;
            }
            tl = tn; lastPkt = st.dwPacketNumber;
            InterlockedIncrement(&g_pkt_changes);
        }
        Sleep(1);
    }
    g_done = -1;
    return 0;
}

LRESULT CALLBACK WndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    static HFONT fTitle, fRate, fNormal;
    if (m == WM_CREATE) {
        fTitle  = CreateFontA(13, 0, 0, 0, FW_MEDIUM, 0, 0, 0, 0, 0, 0, 0, 0, "Segoe UI");
        fRate   = CreateFontA(42, 0, 0, 0, FW_BOLD, 0, 0, 0, 0, 0, 0, 0, 0, "Consolas");
        fNormal = CreateFontA(12, 0, 0, 0, FW_REGULAR, 0, 0, 0, 0, 0, 0, 0, 0, "Consolas");
        SetTimer(h, 1, 125, NULL);
        return 0;
    }
    if (m == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT r; GetClientRect(h, &r);
        SetBkMode(dc, TRANSPARENT);

        LONG pkts = g_pkt_changes, ic = g_icount;
        LONG polls = g_polls;
        if (pkts < 0) pkts = 0;
        int n = ic > MAX_INTERVALS ? MAX_INTERVALS : (int)ic;

        if (g_done < 0) {
            SelectObject(dc, fTitle);
            SetTextColor(dc, RGB(140, 140, 150));
            RECT tr = r; tr.top = 14;
            DrawTextA(dc, "no controller in XInput slot", -1, &tr,
                      DT_CENTER | DT_TOP | DT_SINGLELINE);
            EndPaint(h, &ps); return 0;
        }
        if (pkts <= 0) {
            SelectObject(dc, fTitle);
            SetTextColor(dc, RGB(200, 200, 200));
            RECT tr = r; tr.top = 60;
            DrawTextA(dc, "waiting for controller input...", -1, &tr,
                      DT_CENTER | DT_TOP | DT_SINGLELINE);
            tr.top = 90;
            DrawTextA(dc, "rotate left stick or press buttons", -1, &tr,
                      DT_CENTER | DT_TOP | DT_SINGLELINE);
            EndPaint(h, &ps); return 0;
        }

        /* rolling-window stats */
        int wlen = ROLLING_WINDOW;
        if (n < wlen) wlen = n;
        double *sorted = malloc((size_t)wlen * sizeof(double));
        if (sorted) {
            for (int i = 0; i < wlen; i++) sorted[i] = g_intervals[n - wlen + i];
            qsort(sorted, wlen, sizeof(double), cmp_double);
        }

        double med  = sorted ? percentile(sorted, wlen, 0.50) : 0;
        double avgRoll = sorted ? avg_d(sorted, wlen) : 0;
        double liveHz = avgRoll > 0 ? 1000.0 / avgRoll : 0;
        double jit  = sorted ? stddev_d(sorted, wlen) : 0;
        double mn   = sorted ? min_d(sorted, wlen) : 0;
        double mx   = sorted ? max_d(sorted, wlen) : 0;
        free(sorted);

        /* global stats */
        double *allSorted = NULL;
        if (n > 0) {
            allSorted = malloc((size_t)n * sizeof(double));
            for (int i = 0; i < n; i++) allSorted[i] = g_intervals[i];
            qsort(allSorted, n, sizeof(double), cmp_double);
        }
        double gMed  = allSorted ? percentile(allSorted, n, 0.50) : 0;
        double gAvg  = avg_d(g_intervals, n);
        double gHz   = gAvg > 0 ? 1000.0 / gAvg : 0;
        free(allSorted);

        /* title: controller name */
        SelectObject(dc, fTitle);
        SetTextColor(dc, RGB(130, 130, 140));
        RECT tr = r; tr.top = 10;
        char tit[128];
        snprintf(tit, sizeof tit, "%s  (XInput slot %ld)", g_cname, (long)g_slot);
        DrawTextA(dc, tit, -1, &tr, DT_CENTER | DT_TOP | DT_SINGLELINE);

        /* big rate number */
        SelectObject(dc, fRate);
        if (liveHz >= 250) SetTextColor(dc, RGB(100, 255, 130));
        else if (liveHz >= 125) SetTextColor(dc, RGB(150, 255, 90));
        else if (liveHz >= 60) SetTextColor(dc, RGB(255, 255, 0));
        else SetTextColor(dc, RGB(255, 50, 50));
        RECT rr = r; rr.top = 38;
        char rateStr[32];
        snprintf(rateStr, sizeof rateStr, "%.0f", liveHz);
        DrawTextA(dc, rateStr, -1, &rr, DT_CENTER | DT_TOP | DT_SINGLELINE);

        /* subtitle */
        SelectObject(dc, fTitle);
        SetTextColor(dc, RGB(100, 100, 110));
        RECT sr = r; sr.top = 88;
        DrawTextA(dc, "polling rate  Hz", -1, &sr, DT_CENTER | DT_TOP | DT_SINGLELINE);

        /* stats table */
        SelectObject(dc, fNormal);
        SetTextColor(dc, RGB(180, 180, 190));
        char buf[256];
        snprintf(buf, sizeof buf,
            "Reports  %ld\n"
            "Median   %5.2f ms\n"
            "Jitter   %5.2f ms\n"
            "Min      %5.2f ms\n"
            "Max      %5.2f ms\n"
            "Global   %.0f Hz",
            pkts, gMed, jit, mn, mx, gHz);
        RECT sr2 = r; sr2.top = 114; sr2.left = 24; sr2.right -= 24;
        DrawTextA(dc, buf, -1, &sr2, DT_LEFT | DT_TOP);

        EndPaint(h, &ps);
        return 0;
    }
    if (m == WM_TIMER) { InvalidateRect(h, NULL, TRUE); return 0; }
    if (m == WM_CLOSE) {
        /* write JSON — but never a zero-filled one: no packets means no result */
        KillTimer(h, 1);
        FILE *fp = g_pkt_changes > 0 ? fopen("Z:\\tmp\\poll-live-result.json", "w") : NULL;
        if (fp) {
            LONG ic = g_icount; int n = ic > MAX_INTERVALS ? MAX_INTERVALS : (int)ic;
            double *s = n > 0 ? malloc((size_t)n * sizeof(double)) : NULL;
            if (s) { for (int i = 0; i < n; i++) s[i] = g_intervals[i];
                     qsort(s, n, sizeof(double), cmp_double); }
            double med = s ? percentile(s, n, 0.50) : 0;
            double av  = avg_d(g_intervals, n);
            double jit = s ? stddev_d(s, n) : 0;
            double mn  = s ? min_d(s, n) : 0;
            double mx  = s ? max_d(s, n) : 0;
            free(s);
            fprintf(fp,
                "{\n"
                "  \"tool\": \"crossover-poll-live\",\n"
                "  \"controller\": \"%s\",\n"
                "  \"xinput_slot\": %ld,\n"
                "  \"packet_changes\": %ld,\n"
                "  \"polls_total\": %ld,\n"
                "  \"polling_rate_hz\": %.1f,\n"
                "  \"interval_ms\": {\n"
                "    \"avg\": %.2f,\n"
                "    \"median\": %.2f,\n"
                "    \"jitter_std\": %.2f,\n"
                "    \"min\": %.2f,\n"
                "    \"max\": %.2f\n"
                "  }\n"
                "}\n",
                /* rate from avg, not median: winebus slices one HID report into
                 * ~1.6 dwPacketNumber increments, so the interval distribution is
                 * bimodal and its median is meaningless. avg == packet-changes/sec,
                 * the state-update rate the game actually sees. */
                g_cname, (long)g_slot, (long)g_pkt_changes, (long)g_polls,
                av > 0 ? 1000.0 / av : 0,
                av, med, jit, mn, mx);
            fclose(fp);
        }
        DestroyWindow(h);
        return 0;
    }
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProc(h, m, w, l);
}

int WINAPI WinMain(HINSTANCE hi, HINSTANCE hp, LPSTR cl, int sc)
{
    const char *names[] = {"xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll", NULL};
    HMODULE dll = NULL;
    for (int i = 0; names[i]; i++) {
        dll = LoadLibraryA(names[i]);
        if (dll) {
            XInputGetState = (XIGetState_t)GetProcAddress(dll, "XInputGetState");
            if (XInputGetState) break;
            FreeLibrary(dll); dll = NULL;
        }
    }
    if (!XInputGetState) {
        MessageBoxA(NULL, "XInput DLL not found in this bottle", "poll_live", MB_OK);
        return 3;
    }
    QueryPerformanceFrequency(&g_qpf);

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = WndProc; wc.hInstance = hi;
    wc.lpszClassName = "pollLiveCls";
    wc.hbrBackground = CreateSolidBrush(RGB(30, 30, 36));
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);

    HWND h = CreateWindowA("pollLiveCls", "In-bottle Polling Monitor",
        WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, 300, 260,
        NULL, NULL, hi, NULL);
    ShowWindow(h, SW_SHOW);
    SetForegroundWindow(h);

    CreateThread(NULL, 0, poll_thread, NULL, 0, NULL);

    MSG msg;
    while (GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg); DispatchMessage(&msg);
    }
    return 0;
}
