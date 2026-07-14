#include <winsock2.h>
#include <stdio.h>
#include <stdint.h>
#pragma pack(push,1)
typedef struct { uint32_t magic; uint8_t kind; uint8_t slot; uint16_t buttons; uint32_t packetNumber;
                 uint64_t qpc; uint64_t qpf; uint32_t pollsSince; uint32_t changesSince; uint32_t seq; } BudgetPkt;
#pragma pack(pop)
int main(void) {
    WSADATA w;
    printf("WSAStartup=%d\n", WSAStartup(MAKEWORD(2,2), &w));
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    printf("socket=%lld err=%d\n", (long long)s, WSAGetLastError());
    struct sockaddr_in d = {0};
    d.sin_family = AF_INET; d.sin_port = htons(4517); d.sin_addr.s_addr = inet_addr("127.0.0.1");
    LARGE_INTEGER f, q; QueryPerformanceFrequency(&f);
    for (int i = 0; i < 5; i++) {
        BudgetPkt p = {0}; p.magic = 0x4B4E4C58u; p.kind = i ? 1 : 0;
        QueryPerformanceCounter(&q); p.qpc = (uint64_t)q.QuadPart; p.qpf = (uint64_t)f.QuadPart;
        p.packetNumber = (uint32_t)i; p.seq = (uint32_t)i;
        int r = sendto(s, (const char *)&p, sizeof p, 0, (struct sockaddr *)&d, sizeof d);
        printf("sendto[%d]=%d err=%d (pktsize=%d)\n", i, r, WSAGetLastError(), (int)sizeof p);
        Sleep(50);
    }
    fflush(stdout);
    return 0;
}
