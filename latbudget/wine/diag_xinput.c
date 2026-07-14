#include <windows.h>
#include <stdio.h>
int main(void) {
    HMODULE h = LoadLibraryA("xinput1_4.dll");
    char p[MAX_PATH] = "?";
    if (h) GetModuleFileNameA(h, p, MAX_PATH);
    printf("loaded: %s\n", h ? p : "FAILED");
    if (!h) return 1;
    FARPROC f = GetProcAddress(h, "XInputGetState");
    if (!f) { printf("no XInputGetState\n"); return 1; }
    for (int i = 0; i < 10; i++) {
        unsigned char st[20] = {0};
        DWORD r = ((DWORD (WINAPI*)(DWORD, void*))f)(0, st);
        printf("poll %d -> %lu\n", i, r);
        fflush(stdout);
        Sleep(300);
    }
    return 0;
}
