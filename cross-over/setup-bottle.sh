#!/usr/bin/env bash
set -euo pipefail

# ── CrossOver bottle setup for controller polling tests ──────────────────────
# Creates a clean "input-delay" bottle (Windows 10) with minimal config.

BOTTLE_NAME="input-delay"
CX_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
CX_BOTTLE="$CX_BIN/cxbottle"
WINE="$CX_BIN/wine"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[setup-bottle]${NC} $*"; }
warn() { echo -e "${YELLOW}[setup-bottle] WARNING:${NC} $*"; }
err()  { echo -e "${RED}[setup-bottle] ERROR:${NC} $*"; }

if [[ ! -d "$CX_BIN" ]]; then
    err "CrossOver not found at $CX_BIN"
    err "Install CrossOver from https://www.codeweavers.com/crossover"
    exit 1
fi

BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE_NAME"
if [[ -d "$BOTTLE_DIR" ]]; then
    warn "Bottle '$BOTTLE_NAME' already exists at: $BOTTLE_DIR"
    warn "Run with SKIP_CREATE=1 to skip creation and proceed."
    if [[ "${SKIP_CREATE:-0}" != "1" ]]; then
        err "Bottle already exists. Set SKIP_CREATE=1 to skip, or delete the bottle manually."
        exit 1
    fi
    log "Skipping bottle creation (SKIP_CREATE=1)."
    exit 0
fi

log "Creating CrossOver bottle: '$BOTTLE_NAME' (Windows 10, 64-bit)"

"$CX_BOTTLE" \
    --bottle "$BOTTLE_NAME" \
    --create \
    --template win10 \
    --description "Controller polling latency test bottle"

if [[ ! -d "$BOTTLE_DIR" ]]; then
    err "Bottle directory was not created. Check CrossOver permissions."
    exit 1
fi

log "Bottle created at: $BOTTLE_DIR"

export WINEPREFIX="$BOTTLE_DIR"
log "Verifying Wine inside bottle..."
"$WINE" --version

mkdir -p "$BOTTLE_DIR/drive_c/polling"
log "Working directory: $BOTTLE_DIR/drive_c/polling"
log "Setup complete. Next step: ./install-polling.sh"
