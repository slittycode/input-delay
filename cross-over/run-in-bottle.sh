#!/usr/bin/env bash
set -euo pipefail

# ── Run controller polling test inside the CrossOver bottle ──────────────────
# Launches Polling.exe with latency-relevant Wine debug channels.
# Output goes to cross-over-output/

BOTTLE_NAME="input-delay"
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE_NAME"
CX_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
WINE="$CX_BIN/wine"

SAMPLES="${SAMPLES:-2000}"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/cross-over-output"
mkdir -p "$OUTPUT_DIR"

LOG_FILE="$OUTPUT_DIR/polling-run-${TIMESTAMP}.log"
STDERR_LOG="$OUTPUT_DIR/wine-debug-${TIMESTAMP}.log"

export WINEPREFIX="$BOTTLE_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[polling-bottle]${NC} $*"; }
warn() { echo -e "${YELLOW}[polling-bottle]${NC} $*"; }
info() { echo -e "${CYAN}[polling-bottle]${NC} $*"; }

if [[ ! -f "$BOTTLE_DIR/drive_c/polling/Polling.exe" ]]; then
    echo "ERROR: Polling.exe not found. Run ./install-polling.sh first."
    exit 1
fi

log "Pre-flight: checking if controller is visible inside Wine..."
log ""

info "WINEPREFIX: $WINEPREFIX"
info "Samples:    $SAMPLES"
info ""

log "Launching Polling.exe inside CrossOver bottle..."
log "This will open a terminal window. Follow the Polling UI prompts:"
log "  1. Select your controller from the list"
log "  2. Choose the stick to test (Left recommended)"
log "  3. Rotate the stick continuously until $SAMPLES samples are collected"
log "  4. When prompted, save results via the tool's menu"
log ""

WINEDEBUG="+dinput,+hid,+xinput,+timestamp" \
"$WINE" "C:\\polling\\Polling.exe" 2>"$STDERR_LOG" | tee "$LOG_FILE"

EXIT_CODE=$?

log ""
log "Run complete (exit code: $EXIT_CODE)"

if [[ -f "$STDERR_LOG" ]]; then
    STDERR_SIZE=$(wc -l < "$STDERR_LOG" || echo 0)
    log "Wine debug log: $STDERR_LOG ($STDERR_SIZE lines)"

    if [[ "$STDERR_SIZE" -gt 0 ]]; then
        echo ""
        echo "── Wine debug: controller-related messages ──"
        grep -i -E "joystick|gamepad|xinput|dinput.*device|HID" "$STDERR_LOG" \
            | head -30 || echo "  (no controller messages found)"
        echo ""
    fi
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    warn "Polling.exe exited with code $EXIT_CODE."
    warn "Check the Wine debug log: $STDERR_LOG"
fi

log "Output files:"
log "  Run log:      $LOG_FILE"
log "  Wine debug:   $STDERR_LOG"
log ""
log "Next step: ./run-comparison.sh"
