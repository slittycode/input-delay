#!/usr/bin/env bash
# Stage 2 — button-to-photon latency over multiple clips.
#
# Records nothing itself: you supply 240fps (or faster) video CLIPS that show BOTH the
# controller (an input you can see move — e.g. a face button or the stick) AND the screen
# region that responds. This script opens each clip in inputLagTimer so you mark the
# rectangles + tune thresholds; on exit it writes <clip>.result.json; then it pools all
# clips into a median + spread.
#
# Usage:
#   ./stage2_measure.sh clips/           # process every video in clips/
#   ./stage2_measure.sh a.mp4 b.mp4      # process specific clips
#
# Per clip, inside inputLagTimer:
#   1. Press S, drag the BLUE rectangle over the moving input (button/stick).
#   2. Drag the PURPLE rectangle over the screen area that reacts.
#   3. Watch the top motion bars; press 1/2 (input) and 3/4 (output) to set thresholds
#      just above the noise floor so real motion triggers but idle noise doesn't.
#   4. Let it run through the clip; it collects multiple latency events.
#   5. Press ESC to exit -> result.json is written.
set -uo pipefail
cd "$(dirname "$0")"

PY="inputLagTimer/.venv/bin/python"
ILT="inputLagTimer/inputLagTimer.py"
[ -x "$PY" ] || { echo "venv missing — run: cd inputLagTimer && uv venv --python 3.12 .venv && VIRTUAL_ENV=.venv uv pip install opencv-python numpy"; exit 1; }

# collect clip list
CLIPS=()
if [ "$#" -eq 0 ]; then
  echo "No clips given. Usage: ./stage2_measure.sh clips/   (or list .mp4 files)"; exit 1
fi
for a in "$@"; do
  if [ -d "$a" ]; then
    while IFS= read -r f; do CLIPS+=("$f"); done < <(find "$a" -maxdepth 1 -type f \
      \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.avi' \) | sort)
  elif [ -f "$a" ]; then
    CLIPS+=("$a")
  fi
done

[ "${#CLIPS[@]}" -gt 0 ] || { echo "No video files found."; exit 1; }
echo "Found ${#CLIPS[@]} clip(s). Processing each in inputLagTimer..."

for clip in "${CLIPS[@]}"; do
  echo
  echo ">>> $clip  — mark rectangles (S), tune thresholds (1/2, 3/4), ESC when done."
  "$PY" "$ILT" "$clip" || echo "(inputLagTimer exited non-zero for $clip)"
done

echo
echo "=== Aggregating all clips ==="
python3 stage2_aggregate.py "$@"
