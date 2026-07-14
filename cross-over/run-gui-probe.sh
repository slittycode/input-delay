#!/usr/bin/env bash
# Run the WINDOWED in-bottle XInput probe — RUN THIS IN YOUR OWN Terminal.app.
#
# Why: winebus only receives controller input when a CrossOver/Wine app is actually
# frontmost (the same reason your real games work). Launching from your own terminal
# lets the probe window come to the foreground so you can focus it and move the stick.
#
# Usage:
#   cd ~/code/projects/input-delay/cross-over
#   ./run-gui-probe.sh
#
# Then: a small window titled "In-bottle Controller Probe" appears. CLICK IT to focus,
# then rotate the LEFT stick in circles + press buttons for ~15 seconds. The window shows
# live packet-change counts and the polling rate. When it says DONE, close the window.

set -uo pipefail
cd "$(dirname "$0")"

WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
BOTTLE="Elden Ring Test"
RES="../cross-over-output/inbottle-result.json"
mkdir -p ../cross-over-output
rm -f "$RES"

echo "Launching in-bottle probe window..."
echo ">>> CLICK the window to focus it, then rotate the LEFT STICK for ~15s <<<"
"$WINE" --bottle "$BOTTLE" "$(pwd)/probe_live_gui.exe" >/tmp/gui-probe-user.log 2>&1 &
WPID=$!

# Wait for the app to write its result (after its 15s run). Give generous headroom.
for i in $(seq 1 40); do
  [ -f "$RES" ] && break
  sleep 1
done

echo
if [ -f "$RES" ]; then
  echo "=== IN-BOTTLE RESULT ==="
  cat "$RES"
  echo
  echo "(You can close the probe window now.)"
else
  echo "No result written after 40s."
  echo "If the window never appeared or you couldn't focus it, tell Claude."
fi
