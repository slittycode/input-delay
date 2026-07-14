#!/usr/bin/env bash
# On-demand monitoring HUD for a CrossOver program — nothing is permanently engaged.
#
# Launches the program with Apple's in-process Metal Performance HUD enabled FOR THIS
# RUN ONLY (env var, no bottle config change; draws engine-level FPS — D3D/Metal games
# only, GDI apps won't show it), then attaches the lagtrack overlay on top:
# compositor FPS, frametimes, instant per-press input→present readout, CSV log.
#
# Usage:
#   ./monitor.sh "<Bottle Name>" "<path\to\program.exe>" ["window match"]
#   ./monitor.sh --attach "<window match>"      # program already running
#
# Stop with Ctrl-C — lagtrack prints the session summary; the game keeps running.

set -uo pipefail
cd "$(dirname "$0")"
WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
LAGTRACK="./.build/release/lagtrack"

if [ "${1:-}" = "--attach" ]; then
  QUERY="${2:?usage: ./monitor.sh --attach \"window match\"}"
else
  BOTTLE="${1:?usage: ./monitor.sh \"Bottle\" \"program.exe\" [\"window match\"]}"
  EXE="${2:?usage: ./monitor.sh \"Bottle\" \"program.exe\" [\"window match\"]}"
  QUERY="${3:-$(basename "${EXE%.*}")}"
  echo "monitor: launching in '$BOTTLE' with Metal HUD (this run only)…"
  MTL_HUD_ENABLED=1 "$WINE" --bottle "$BOTTLE" "$EXE" >/dev/null 2>&1 &
fi

echo "monitor: waiting for a window matching \"$QUERY\"…"
for _ in $(seq 1 60); do
  if "$LAGTRACK" --list 2>/dev/null | grep -qi "$QUERY"; then
    exec "$LAGTRACK" --overlay "$QUERY"
  fi
  sleep 2
done
echo "monitor: no window matching \"$QUERY\" appeared within 2 min" >&2
exit 1
