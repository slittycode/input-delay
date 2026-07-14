/*
 * xinput_proxy.c — STAGE 2: in-bottle XInput timestamping proxy for Wine/CrossOver.
 *
 * Drop-in xinput1_4.dll that forwards every call to the real (builtin) XInput and,
 * on each dwPacketNumber change observed at the GAME'S OWN POLL, timestamps it with
 * QueryPerformanceCounter (mach-clock based under Wine → host-correlatable) and emits
 * a 40-byte UDP packet to the host collector (latbudget) on 127.0.0.1:4517.
 *
 * The timestamp is the poll at which the game could first SEE the new state — that is
 * the honest stage boundary (includes waiting for the game's poll cadence).
 *
 * No SDL, no wall clock, no polling of our own — we ride the game's calls.
 *
 * Build:   ./build-proxy.sh   (x86_64-w64-mingw32-gcc)
 * Install: ./install-proxy.sh "<dir containing the game exe>"
 * Run:     WINEDLLOVERRIDES="xinput1_4=n,b" wine --bottle <B> <game.exe>
 */
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;         /* 'XLNK' 0x4B4E4C58 */
    uint8_t  kind;          /* 0 hello, 1 packet-change, 2 poll-stats */
    uint8_t  slot;
    uint16_t buttons;
    uint32_t packetNumber;
    uint64_t qpc;
    uint64_t qpf;
    uint32_t pollsSince;
    uint32_t changesSince;
    uint32_t seq;
} BudgetPkt;                /* 40 bytes */
#pragma pack(pop)

#define PKT_MAGIC 0x4B4E4C58u
#define DEST_PORT 4517

typedef struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger;
                 SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } XINPUT_GAMEPAD_;
typedef struct { DWORD dwPacketNumber; XINPUT_GAMEPAD_ Gamepad; } XINPUT_STATE_;

typedef DWORD (WINAPI *pGetState)(DWORD, XINPUT_STATE_ *);
typedef DWORD (WINAPI *pSetState)(DWORD, void *);
typedef DWORD (WINAPI *pGetCaps)(DWORD, DWORD, void *);
typedef void  (WINAPI *pEnable)(BOOL);
typedef DWORD (WINAPI *pGetBattery)(DWORD, BYTE, void *);
typedef DWORD (WINAPI *pGetKeystroke)(DWORD, DWORD, void *);

static HINSTANCE g_self;
static HMODULE g_real;
static pGetState real_GetState, real_GetStateEx;
static pSetState real_SetState;
static pGetCaps real_GetCaps;
static pEnable real_Enable;
static pGetBattery real_GetBattery;
static pGetKeystroke real_GetKeystroke;

static CRITICAL_SECTION g_cs;
static volatile LONG g_inited;
static SOCKET g_sock = INVALID_SOCKET;
static struct sockaddr_in g_dest;
static uint64_t g_qpf, g_lastStatsQpc;
static DWORD g_lastPacket[4];
static uint32_t g_polls, g_changes, g_seq;

#include <stdio.h>
/* XLNK_DEBUG=1 → append init/send diagnostics to Z:\tmp\xlnk-debug.log (host /tmp) */
static void dbg(const char *msg, long v1, long v2)
{
    /* Z:\tmp = host /tmp — diagnostics never touch the bottle. */
    char line[256];
    int n = snprintf(line, sizeof line, "xlnk: %s v1=%ld v2=%ld\n", msg, v1, v2);
    HANDLE h = CreateFileA("Z:\\tmp\\xlnk-debug.log", FILE_APPEND_DATA,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(h, line, (DWORD)n, &written, NULL);
    CloseHandle(h);
}

static void load_real(void)
{
    char path[MAX_PATH];
    UINT n = GetSystemDirectoryA(path, MAX_PATH);
    if (n && n < MAX_PATH - 16) {
        lstrcatA(path, "\\xinput1_4.dll");
        g_real = LoadLibraryA(path);
    }
    /* Wine resolves the system32 fakedll to the builtin. If overrides ever made us
     * load OURSELVES, fall back to a basename we don't proxy. */
    if (g_real == (HMODULE)g_self) { FreeLibrary(g_real); g_real = NULL; }
    if (!g_real) g_real = LoadLibraryA("xinput9_1_0.dll");
    if (!g_real) return;
    real_GetState     = (pGetState)GetProcAddress(g_real, "XInputGetState");
    real_GetStateEx   = (pGetState)GetProcAddress(g_real, (LPCSTR)100);
    real_SetState     = (pSetState)GetProcAddress(g_real, "XInputSetState");
    real_GetCaps      = (pGetCaps)GetProcAddress(g_real, "XInputGetCapabilities");
    real_Enable       = (pEnable)GetProcAddress(g_real, "XInputEnable");
    real_GetBattery   = (pGetBattery)GetProcAddress(g_real, "XInputGetBatteryInformation");
    real_GetKeystroke = (pGetKeystroke)GetProcAddress(g_real, "XInputGetKeystroke");
}

static void emit(uint8_t kind, uint8_t slot, uint16_t buttons, uint32_t packetNumber)
{
    if (g_sock == INVALID_SOCKET) return;
    BudgetPkt p;
    LARGE_INTEGER qpc;
    QueryPerformanceCounter(&qpc);
    p.magic = PKT_MAGIC;
    p.kind = kind;
    p.slot = slot;
    p.buttons = buttons;
    p.packetNumber = packetNumber;
    p.qpc = (uint64_t)qpc.QuadPart;
    p.qpf = g_qpf;
    p.pollsSince = g_polls;
    p.changesSince = g_changes;
    p.seq = g_seq++;
    int rc = sendto(g_sock, (const char *)&p, sizeof p, 0,
                    (const struct sockaddr *)&g_dest, sizeof g_dest);
    if (rc != (int)sizeof p) dbg("sendto failed", rc, WSAGetLastError());
}

static void ensure_init(void)
{
    if (g_inited) return;
    EnterCriticalSection(&g_cs);
    if (!g_inited) {
        WSADATA wsa;
        LARGE_INTEGER f;
        load_real();
        if (WSAStartup(MAKEWORD(2, 2), &wsa) == 0) {
            g_sock = socket(AF_INET, SOCK_DGRAM, 0);
            if (g_sock != INVALID_SOCKET) {
                u_long nb = 1;
                ioctlsocket(g_sock, FIONBIO, &nb);
                g_dest.sin_family = AF_INET;
                g_dest.sin_port = htons(DEST_PORT);
                g_dest.sin_addr.s_addr = inet_addr("127.0.0.1");
            }
        }
        QueryPerformanceFrequency(&f);
        g_qpf = (uint64_t)f.QuadPart;
        dbg("init done: real/sock", (long)(g_real != NULL), (long)(g_sock != INVALID_SOCKET));
        emit(0, 0, 0, 0); /* hello */
        dbg("hello emitted", (long)g_seq, (long)g_qpf);
        g_inited = 1;
    }
    LeaveCriticalSection(&g_cs);
}

static DWORD get_state_common(pGetState fn, DWORD user, XINPUT_STATE_ *st)
{
    DWORD r;
    ensure_init();
    if (!fn) return 1167; /* ERROR_DEVICE_NOT_CONNECTED */
    r = fn(user, st);
    if (r == 0 && user < 4) {
        g_polls++;
        if (st->dwPacketNumber != g_lastPacket[user]) {
            g_lastPacket[user] = st->dwPacketNumber;
            g_changes++;
            emit(1, (uint8_t)user, st->Gamepad.wButtons, st->dwPacketNumber);
        }
        if (g_qpf) {
            LARGE_INTEGER now;
            QueryPerformanceCounter(&now);
            if ((uint64_t)now.QuadPart - g_lastStatsQpc > 2 * g_qpf) {
                emit(2, (uint8_t)user, 0, 0);
                g_polls = 0;
                g_changes = 0;
                g_lastStatsQpc = (uint64_t)now.QuadPart;
            }
        }
    }
    return r;
}

DWORD WINAPI XInputGetState(DWORD user, XINPUT_STATE_ *st)
{
    return get_state_common(real_GetState, user, st);
}

/* ordinal 100 — undocumented XInputGetStateEx (guide button); many games use it */
DWORD WINAPI XInputGetStateEx(DWORD user, XINPUT_STATE_ *st)
{
    return get_state_common(real_GetStateEx ? real_GetStateEx : real_GetState, user, st);
}

DWORD WINAPI XInputSetState(DWORD user, void *vib)
{
    ensure_init();
    return real_SetState ? real_SetState(user, vib) : 1167;
}

DWORD WINAPI XInputGetCapabilities(DWORD user, DWORD flags, void *caps)
{
    ensure_init();
    return real_GetCaps ? real_GetCaps(user, flags, caps) : 1167;
}

void WINAPI XInputEnable(BOOL enable)
{
    ensure_init();
    if (real_Enable) real_Enable(enable);
}

DWORD WINAPI XInputGetBatteryInformation(DWORD user, BYTE type, void *info)
{
    ensure_init();
    return real_GetBattery ? real_GetBattery(user, type, info) : 1167;
}

DWORD WINAPI XInputGetKeystroke(DWORD user, DWORD reserved, void *ks)
{
    ensure_init();
    return real_GetKeystroke ? real_GetKeystroke(user, reserved, ks) : 1167;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = inst;
        InitializeCriticalSection(&g_cs);
        DisableThreadLibraryCalls(inst);
        /* no socket/library work here — loader lock; ensure_init is lazy */
    }
    return TRUE;
}
