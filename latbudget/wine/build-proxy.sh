#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -o xinput1_4.dll xinput_proxy.c xinput1_4.def -lws2_32
echo "built: $(pwd)/xinput1_4.dll"
