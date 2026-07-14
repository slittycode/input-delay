/*
 * probe_live_gui.c — WINDOWED in-bottle XInput polling tester for CrossOver/Wine.
 *
 * Unlike the console probe, this creates a real Win32 window so winemac.drv makes it a
 * frontmost Cocoa app — the condition under which macOS GameController delivers controller
 * INPUT (the same reason real games work but a windowless probe does not).
 *
 * A background thread tight-polls XInputGetState (~1 kHz), counts packet-number changes,
 * and records the wall-clock interval between changes to estimate the in-bottle polling
 * rate the game sees THROUGH CrossOver. Live stats are drawn in the window; a JSON summary
 * is written to Z:\...\cross-over-output\inbottle-result.json after DURATION_S.
 *
 * Compile: x86_64-w64-mingw32-gcc -O2 -mwindows -o probe_live_gui.exe probe_live_gui.c
 */
#include <windows.h>
#include <stdio.h>

#pragma pack(push, 4)
typedef struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger;
                 SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } XINPUT_GAMEPAD;
typedef struct { DWORD dwPacketNumber; XINPUT_GAMEPAD Gamepad; } XINPUT_STATE;
#pragma pack(pop)
typedef DWORD (WINAPI *XIGetState_t)(DWORD, XINPUT_STATE*);

#define DURATION_S 15
#define OUT_PATH "Z:\\Users\\christiansmith\\code\\projects\\input-delay\\cross-over-output\\inbottle-result.json"

static volatile LONG g_polls=0, g_pkt=0, g_slot=-1, g_done=0;
static volatile LONG g_lx=0, g_ly=0; static volatile DWORD g_btn=0;
static double g_min=1e9, g_avg=0, g_max=0; static long g_intervals=0;
static XIGetState_t XInputGetState=NULL;

DWORD WINAPI poll_thread(LPVOID p) {
    LARGE_INTEGER f,t0,tn,tl; QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0); tl=t0;
    int slot=-1; XINPUT_STATE s;
    for (int i=0;i<4;i++) if (XInputGetState(i,&s)==ERROR_SUCCESS){slot=i;break;}
    g_slot=slot; if (slot<0){g_done=1;return 0;}
    DWORD last=0; int have=0; double sum=0;
    for (;;) {
        XINPUT_STATE st;
        if (XInputGetState(slot,&st)!=ERROR_SUCCESS){break;}
        InterlockedIncrement(&g_polls);
        g_lx=st.Gamepad.sThumbLX; g_ly=st.Gamepad.sThumbLY; g_btn=st.Gamepad.wButtons;
        if(!have){last=st.dwPacketNumber;have=1;}
        else if(st.dwPacketNumber!=last){
            QueryPerformanceCounter(&tn);
            double dt=(double)(tn.QuadPart-tl.QuadPart)*1000.0/f.QuadPart;
            if(dt>0&&dt<500){sum+=dt;g_intervals++;if(dt<g_min)g_min=dt;if(dt>g_max)g_max=dt;g_avg=sum/g_intervals;}
            tl=tn; last=st.dwPacketNumber; InterlockedIncrement(&g_pkt);
        }
        QueryPerformanceCounter(&tn);
        double el=(double)(tn.QuadPart-t0.QuadPart)/f.QuadPart;
        if(el>=DURATION_S) break;
        Sleep(1);
    }
    /* write JSON summary */
    FILE*fp=fopen(OUT_PATH,"w");
    if(fp){
        if(g_intervals>0)
            fprintf(fp,"{\n  \"tool\": \"crossover-inbottle-xinput-gui\",\n  \"slot\": %ld,\n"
                "  \"polls\": %ld,\n  \"packet_changes\": %ld,\n  \"polling_rate_hz\": %.1f,\n"
                "  \"interval_ms\": {\"min\": %.2f, \"avg\": %.2f, \"max\": %.2f},\n"
                "  \"verdict\": \"LIVE input through CrossOver\"\n}\n",
                (long)g_slot,(long)g_polls,(long)g_pkt,1000.0/g_avg,g_min,g_avg,g_max);
        else
            fprintf(fp,"{\n  \"tool\": \"crossover-inbottle-xinput-gui\",\n  \"slot\": %ld,\n"
                "  \"polls\": %ld,\n  \"packet_changes\": 0,\n  \"polling_rate_hz\": null,\n"
                "  \"verdict\": \"connected but ZERO input even as foreground window\"\n}\n",
                (long)g_slot,(long)g_polls);
        fclose(fp);
    }
    g_done=1;
    return 0;
}

LRESULT CALLBACK WndProc(HWND h,UINT m,WPARAM w,LPARAM l){
    if(m==WM_PAINT){
        PAINTSTRUCT ps; HDC dc=BeginPaint(h,&ps);
        char buf[512];
        snprintf(buf,sizeof buf,
            "In-bottle XInput probe (keep this window focused, rotate LEFT stick)\n\n"
            "slot=%ld  polls=%ld  packet-changes=%ld\n"
            "LX=%ld  LY=%ld  buttons=0x%04lx\n"
            "interval ms: min=%.2f avg=%.2f max=%.2f\n"
            "polling rate ~= %.1f Hz\n%s",
            (long)g_slot,(long)g_polls,(long)g_pkt,(long)g_lx,(long)g_ly,(unsigned long)g_btn,
            g_min>1e8?0:g_min,g_avg,g_max, g_avg>0?1000.0/g_avg:0.0,
            g_done?"\nDONE - result written to cross-over-output/inbottle-result.json":"");
        RECT r; GetClientRect(h,&r); r.left=10; r.top=10;
        DrawTextA(dc,buf,-1,&r,DT_LEFT|DT_TOP|DT_NOCLIP);
        EndPaint(h,&ps); return 0;
    }
    if(m==WM_TIMER){ InvalidateRect(h,NULL,TRUE); if(g_done){KillTimer(h,1);} return 0; }
    if(m==WM_DESTROY){ PostQuitMessage(0); return 0; }
    return DefWindowProc(h,m,w,l);
}

int WINAPI WinMain(HINSTANCE hi,HINSTANCE hp,LPSTR cl,int sc){
    const char*names[]={"xinput1_4.dll","xinput1_3.dll","xinput9_1_0.dll",NULL};
    HMODULE dll=NULL;
    for(int i=0;names[i];i++){dll=LoadLibraryA(names[i]);
        if(dll){XInputGetState=(XIGetState_t)GetProcAddress(dll,"XInputGetState");
            if(XInputGetState)break; FreeLibrary(dll);dll=NULL;}}
    if(!XInputGetState){MessageBoxA(NULL,"XInput DLL not found","probe",MB_OK);return 3;}

    WNDCLASSA wc={0}; wc.lpfnWndProc=WndProc; wc.hInstance=hi; wc.lpszClassName="probecls";
    wc.hbrBackground=(HBRUSH)(COLOR_WINDOW+1); RegisterClassA(&wc);
    HWND h=CreateWindowA("probecls","In-bottle Controller Probe",WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,CW_USEDEFAULT,560,240,NULL,NULL,hi,NULL);
    ShowWindow(h,SW_SHOW); SetForegroundWindow(h); SetActiveWindow(h);
    SetTimer(h,1,100,NULL);
    CreateThread(NULL,0,poll_thread,NULL,0,NULL);

    MSG msg;
    while(GetMessage(&msg,NULL,0,0)){ TranslateMessage(&msg); DispatchMessage(&msg); }
    return 0;
}
