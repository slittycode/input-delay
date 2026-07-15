#!/usr/bin/env bash
# Launch the live in-bottle XInput polling dashboard.
#
# Usage: ./run-poll-live.sh [bottle-name]
# Default: "Elden Ring Test"
set -euo pipefail
cd "$(dirname "$0")"

WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
BOTTLE="${1:-Elden Ring Test}"
RES="/tmp/poll-live-result.json"
rm -f "$RES"

# poll_live.exe is gitignored — build it if missing or older than the source
if [ ! -f poll_live.exe ] || [ poll_live.c -nt poll_live.exe ]; then
  echo "Building poll_live.exe..."
  x86_64-w64-mingw32-gcc -O2 -mwindows -o poll_live.exe poll_live.c
fi

echo "Launching in-bottle polling monitor in bottle '${BOTTLE}'..."
echo "Focus the window, then move the controller. Close the window to print results."
echo ""

"$WINE" --bottle "$BOTTLE" "$(pwd)/poll_live.exe" >/tmp/poll-live-user.log 2>&1 &
WPID=$!

# Poll for result JSON after window closes
for i in $(seq 1 120); do
  if [ -f "$RES" ]; then
    echo ""
    echo "=== IN-BOTTLE RESULT ==="
    cat "$RES"
    exit 0
  fi
  kill -0 $WPID 2>/dev/null || break
  sleep 1
done

echo "Window closed without writing result."
