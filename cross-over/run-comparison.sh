#!/usr/bin/env bash
set -euo pipefail

# ── Controller polling comparison: Native vs CrossOver (Wine) ────────────────
# Runs gamepadla-plus natively, then Polling.exe inside the bottle,
# and produces a side-by-side comparison table.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GAMEPADLA_PLUS="$PROJECT_DIR/gamepadla-plus"
OUTPUT_DIR="$PROJECT_DIR/cross-over-output"
COMPARISON_TABLE="$PROJECT_DIR/comparison-table.md"

BOTTLE_NAME="input-delay"
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE_NAME"
CX_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
WINE="$CX_BIN/wine"

SAMPLES="${SAMPLES:-2000}"
TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
mkdir -p "$OUTPUT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[comparison]${NC} $*"; }
warn()   { echo -e "${YELLOW}[comparison]${NC} $*"; }
section(){ echo ""; echo -e "${CYAN}═══ $* ═══${NC}"; echo ""; }

# ── Helper: parse JSON and extract key metrics ──────────────────────────────

parse_json() {
    local file="$1"
    python3 -c "
import json, sys
with open('$file') as f:
    d = json.load(f)
pr = d.get('polling_rate', '?')
jitter = d.get('jitter', '?')
min_l = d.get('min_latency', d.get('filteredMin', '?'))
avg_l = d.get('avg_latency', d.get('filteredAverage_rounded', '?'))
max_l = d.get('max_latency', d.get('filteredMax', '?'))
print(f'{pr}|{jitter}|{min_l}|{avg_l}|{max_l}')
" 2>/dev/null || echo "?|?|?|?|?"
}

delta() {
    local a="$1" b="$2"
    if [[ "$a" == "?" ]] || [[ "$b" == "?" ]]; then
        echo "?"
    else
        python3 -c "print(round($b - $a, 2))"
    fi
}

# ── Phase 1: Native test ─────────────────────────────────────────────────────

section "PHASE 1: Native (macOS) polling-rate test"

NATIVE_SUCCESS=0
NATIVE_JSON=""

if [[ -d "$GAMEPADLA_PLUS" ]]; then
    NATIVE_JSON="$OUTPUT_DIR/native-result-${TIMESTAMP}.json"
    log "Running: uv run gamepadla test --samples $SAMPLES --out $NATIVE_JSON ..."

    (cd "$GAMEPADLA_PLUS" && uv run gamepadla test \
        --samples "$SAMPLES" \
        --out "$NATIVE_JSON" \
        --stick LEFT \
        --id 0 \
        2>&1)
    EXIT_CODE=$?

    if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$NATIVE_JSON" ]]; then
        log "Native test complete."
        NATIVE_SUCCESS=1
    else
        warn "Native test failed or produced no output (exit: $EXIT_CODE)."
        warn "Stage 1 input capture may still be blocked. Proceeding with bottle test only."
    fi
else
    warn "gamepadla-plus directory not found at $GAMEPADLA_PLUS"
fi

# ── Phase 2: In-bottle test ─────────────────────────────────────────────────

section "PHASE 2: CrossOver (Wine) in-bottle polling test"

BOTTLE_SUCCESS=0
BOTTLE_JSON=""

if [[ -f "$BOTTLE_DIR/drive_c/polling/Polling.exe" ]]; then
    export WINEPREFIX="$BOTTLE_DIR"

    BOTTLE_LOG="$OUTPUT_DIR/bottle-run-${TIMESTAMP}.log"
    BOTTLE_DEBUG="$OUTPUT_DIR/bottle-debug-${TIMESTAMP}.log"
    BOTTLE_JSON="$OUTPUT_DIR/bottle-result-${TIMESTAMP}.json"

    log "Launching Polling.exe..."
    log ""
    log "YOU must interact with the Polling UI:"
    log "  1. Select controller from list"
    log "  2. Choose stick (Left recommended)"
    log "  3. Rotate stick continuously for $SAMPLES samples"
    log "  4. Save results when prompted (the tool has a save/export option)"
    log ""

    WINEDEBUG="+dinput,+hid,+xinput,+timestamp" \
    "$WINE" "C:\\polling\\Polling.exe" 2>"$BOTTLE_DEBUG" | tee "$BOTTLE_LOG"

    # Polling.exe may or may not output JSON automatically.
    # If the user saved a JSON file inside the bottle, extract it.
    BOTTLE_JSON_CANDIDATE="$BOTTLE_DIR/drive_c/polling/data.json"
    if [[ -f "$BOTTLE_JSON_CANDIDATE" ]]; then
        cp "$BOTTLE_JSON_CANDIDATE" "$BOTTLE_JSON"
        BOTTLE_SUCCESS=1
        log "In-bottle result JSON copied to: $BOTTLE_JSON"
    else
        # Try to parse the run log for a results table
        log "No data.json found in bottle. Checking run log for results..."
        if grep -q "Polling Rate" "$BOTTLE_LOG" 2>/dev/null; then
            log "Results found in log output (manual extraction needed)."
        else
            warn "No structured results found."
            warn "The controller may not be visible inside Wine's dinput."
        fi
    fi
else
    warn "Polling.exe not found. Run ./install-polling.sh first."
fi

# ── Phase 3: Parse and compare ───────────────────────────────────────────────

section "PHASE 3: Comparison"

NATIVE="?|?|?|?|?"
BOTTLE="?|?|?|?|?"

[[ "$NATIVE_SUCCESS" -eq 1 ]] && NATIVE=$(parse_json "$NATIVE_JSON")
[[ "$BOTTLE_SUCCESS" -eq 1 ]] && BOTTLE=$(parse_json "$BOTTLE_JSON")

IFS='|' read -r N_PR N_JIT N_MIN N_AVG N_MAX <<< "$NATIVE"
IFS='|' read -r B_PR B_JIT B_MIN B_AVG B_MAX <<< "$BOTTLE"

D_PR=$(delta "$N_PR" "$B_PR")
D_JIT=$(delta "$N_JIT" "$B_JIT")
D_MIN=$(delta "$N_MIN" "$B_MIN")
D_AVG=$(delta "$N_AVG" "$B_AVG")
D_MAX=$(delta "$N_MAX" "$B_MAX")

cat > "$COMPARISON_TABLE" << MDEOF
# CrossOver Input-Path Overhead: Native vs In-Bottle

> Generated: $(date +"%Y-%m-%d %H:%M:%S")
> Samples per test: $SAMPLES
> Controller: Xbox Series X/S (Bluetooth)
> Native tool: gamepadla-plus (pygame/SDL2 -> Apple GameController framework)
> In-bottle tool: cakama3a/Polling v${POLLING_TAG:-?} (pygame/SDL2 -> Wine dinput -> macOS HID)

## Results

| Metric | Native (macOS) | CrossOver (Wine) | Delta (Overhead) | Interpretation |
|--------|---------------|------------------|------------------|----------------|
| Polling Rate Avg. (Hz) | $N_PR | $B_PR | $D_PR | Negative delta = Wine adds latency between reports |
| Interval Min (ms) | $N_MIN | $B_MIN | $D_MIN | Minimum report interval — hardware floor |
| Interval Avg. (ms) | $N_AVG | $B_AVG | $D_AVG | **Primary overhead metric** — average added delay from Wine translation |
| Interval Max (ms) | $N_MAX | $B_MAX | $D_MAX | Worst-case interval — jitter amplification |
| Jitter (ms) | $N_JIT | $B_JIT | $D_JIT | Report-to-report consistency |

## Interpretation

- \`Delta > 0\` on interval columns = CrossOver adds that many ms between controller reports.
- \`?\` = data unavailable (native test blocked, or controller not visible in bottle).
- These are **polling-rate / report-interval** metrics. They measure how often
  reports arrive, not true button-to-photon latency. For end-to-end, see Stage 2.

## Raw Output Files

| Source | File |
|--------|------|
| Native JSON | \`$NATIVE_JSON\` |
| Bottle JSON | \`$BOTTLE_JSON\` |
| Bottle run log | \`$BOTTLE_LOG\` |
| Wine debug log | \`$BOTTLE_DEBUG\` |
MDEOF

section "Comparison table written to: $COMPARISON_TABLE"
cat "$COMPARISON_TABLE"
echo ""
log "Done."
