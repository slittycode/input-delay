#!/usr/bin/env bash
# One-run controller test battery — retests every "impossible" conclusion from scratch.
#
#   1. gcprobe   — GCController + shouldMonitorBackgroundEvents (background delivery?)
#   2. hidmon    — raw IOHIDManager reports, now WITH Input Monitoring granted
#   3. probe_live.exe (windowless, in-bottle) — does a background bottle process get
#      XInput packets while a SAME-BOTTLE window is frontmost? (The old "0 packets"
#      test ran with no bottle window frontmost at all.)
#
# Usage: connect the pad, then  ./run-battery.sh
# When the "In-bottle Controller Probe" window appears: FOCUS IT and rotate the left
# stick + press buttons continuously until the script says done (~30 s).

set -uo pipefail
cd "$(dirname "$0")"
WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
BOTTLE="Elden Ring Test"
OUT="battery-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo ">>> starting native probes (gcprobe, hidmon)…"
./gcprobe > "$OUT/gcprobe.log" 2>&1 &
GC=$!
./hidmon > "$OUT/hidmon.log" 2>&1 &
HM=$!

rm -f ../cross-over-output/inbottle-result.json
echo ">>> launching in-bottle GUI probe — FOCUS ITS WINDOW, rotate stick + press buttons"
"$WINE" --bottle "$BOTTLE" "$(pwd)/../cross-over/probe_live_gui.exe" > "$OUT/gui.log" 2>&1 &

sleep 10
echo ">>> starting WINDOWLESS in-bottle poller — KEEP ROTATING for ~15 s more…"
"$WINE" --bottle "$BOTTLE" "$(pwd)/../cross-over/probe_live.exe" > "$OUT/probe_live.log" 2>&1
echo ">>> windowless poller finished. You can stop. Collecting native probes (~1 min)…"

wait "$GC" "$HM" 2>/dev/null

echo
echo "════════ RESULTS ════════"
echo "── 1. GCController background events ──"
tail -12 "$OUT/gcprobe.log"
echo
echo "── 2. raw IOHID with Input Monitoring ──"
tail -12 "$OUT/hidmon.log"
echo
echo "── 3. in-bottle WINDOWLESS poller (same-bottle window frontmost) ──"
cat "$OUT/probe_live.log"
echo
echo "── (reference) in-bottle GUI probe ──"
cat ../cross-over-output/inbottle-result.json 2>/dev/null || echo "(no result json written)"
echo
echo "logs saved in gcprobe/$OUT/"
