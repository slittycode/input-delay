#!/usr/bin/env bash
# validate-pollrate.sh — run --pollrate on Bluetooth and confirm the number
# matches the known-good reference (~66-68 Hz BT, per browser API + stage B).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$HERE/.build/release"
BINARY="$BUILD_DIR/latbudget"
DURATION=15
MIN_HZ=60
MAX_HZ=72

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "validate-pollrate: checking binary..."
if [[ ! -x "$BINARY" ]]; then
    echo "  building first..."
    (cd "$HERE" && swift build -c release)
fi

echo "validate-pollrate: running --pollrate (${DURATION}s) on Bluetooth..."
echo "  Rotate the LEFT stick in continuous circles."
echo "  Ctrl-C also ends early if you get enough data."
echo ""

RESULT=$("$BINARY" --pollrate --duration "$DURATION" 2>/dev/null) || {
    echo -e "${RED}[FAIL]${NC} --pollrate exited non-zero"
    echo "  Stderr output:"
    "$BINARY" --pollrate --duration "$DURATION" 2>&1 >/dev/null
    exit 1
}

HZ=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['polling_rate_hz'])" 2>/dev/null || echo "")
if [[ -z "$HZ" ]]; then
    echo -e "${RED}[FAIL]${NC} could not parse polling_rate_hz from output"
    echo "$RESULT"
    exit 1
fi

echo ""
echo "  Measured: ${HZ} Hz"
echo "  Expected range: ${MIN_HZ}–${MAX_HZ} Hz (Bluetooth, 66–68 Hz ± tolerance)"
echo ""

if (( $(echo "$HZ < $MIN_HZ" | bc -l) )) || (( $(echo "$HZ > $MAX_HZ" | bc -l) )); then
    echo -e "${RED}[FAIL]${NC} polling rate $HZ Hz is outside expected range $MIN_HZ–$MAX_HZ Hz"
    echo "  This means --pollrate disagrees with the browser API (~66 Hz BT)"
    echo "  and with latbudget stage B (~66 Hz BT). Investigate before trusting."
    echo ""
    echo "Full output:"
    echo "$RESULT"
    exit 1
fi

echo -e "${GREEN}[PASS]${NC} --pollrate agrees with the reference ($HZ Hz, expected $MIN_HZ–$MAX_HZ Hz)"
echo ""
echo "Summary:"
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"
