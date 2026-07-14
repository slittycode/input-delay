#!/usr/bin/env bash
# Stage 1 self-test — RUN THIS IN YOUR OWN Terminal.app (not via Claude).
#
# Purpose: prove whether the controller feeds pygame/SDL at all when launched from
# a genuine foreground GUI terminal. If input registers here but not inside Claude's
# execution context, the blocker is the sandbox/activation context, not your hardware.
#
# Usage:
#   cd ~/code/projects/input-delay
#   ./stage1_selftest.sh
#
# A small window opens. Rotate BOTH sticks in circles and press some face buttons
# for ~12 seconds. Watch the numbers: if `axisChg` / `btnEvt` climb above 0, input
# is flowing. Then run the real test (printed at the end).

set -euo pipefail
cd "$(dirname "$0")/gamepadla-plus"

echo "=== Controllers pygame can see ==="
uv run gamepadla list || true
echo
echo "=== Live input capture (12s) — MOVE STICKS + PRESS BUTTONS NOW ==="
uv run python diag_axes2.py 12

cat <<'EOF'

------------------------------------------------------------------
If axisChg / btnEvt went above 0, input works from this terminal.
Run the REAL polling-rate test (rotate the LEFT stick slowly at the
edge, continuously, until the bar fills — ~2000 samples):

    cd ~/code/projects/input-delay/gamepadla-plus
    uv run gamepadla test --stick left --out ../stage1_result.json

Fewer samples for a quicker first look:

    uv run gamepadla test --stick left --samples 500 --out ../stage1_result_quick.json
------------------------------------------------------------------
EOF
