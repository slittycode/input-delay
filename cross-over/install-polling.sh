#!/usr/bin/env bash
set -euo pipefail

# ── Install Windows Polling.exe into the CrossOver bottle ────────────────────
# Downloads cakama3a/Polling.exe (PyInstaller bundle) from GitHub Releases.

POLLING_TAG="1.3.1.4"
POLLING_URL="https://github.com/cakama3a/Polling/releases/download/${POLLING_TAG}/Polling.exe"

BOTTLE_NAME="input-delay"
BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE_NAME"
DEST_EXE="$BOTTLE_DIR/drive_c/polling/Polling.exe"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR/polling-exe"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install-polling]${NC} $*"; }
warn() { echo -e "${YELLOW}[install-polling] WARNING:${NC} $*"; }
err()  { echo -e "${RED}[install-polling] ERROR:${NC} $*"; }

if [[ ! -d "$BOTTLE_DIR" ]]; then
    err "Bottle '$BOTTLE_NAME' not found. Run ./setup-bottle.sh first."
    exit 1
fi

if [[ -f "$DEST_EXE" ]]; then
    log "Polling.exe already installed at: $DEST_EXE"
    log "Run with FORCE_DOWNLOAD=1 to re-download."
    if [[ "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
        exit 0
    fi
fi

log "Downloading Polling.exe v${POLLING_TAG} from GitHub..."

mkdir -p "$LOCAL_DIR" "$BOTTLE_DIR/drive_c/polling"

if command -v curl &>/dev/null; then
    curl -L --progress-bar -o "$LOCAL_DIR/Polling.exe" "$POLLING_URL"
else
    err "curl not found. Install curl to download Polling.exe."
    exit 1
fi

log "Downloaded $(du -h "$LOCAL_DIR/Polling.exe" | cut -f1)"

cp "$LOCAL_DIR/Polling.exe" "$DEST_EXE"
log "Copied Polling.exe to: $DEST_EXE"

# Also copy the standalone probe_controller.exe
PROBE_SRC="$SCRIPT_DIR/probe_controller.exe"
PROBE_DEST="$BOTTLE_DIR/drive_c/polling/probe_controller.exe"
if [[ -f "$PROBE_SRC" ]]; then
    cp "$PROBE_SRC" "$PROBE_DEST"
    log "Copied probe to: $PROBE_DEST"
else
    warn "probe_controller.exe not found at $PROBE_SRC — run compile first"
fi

log "Install complete. Next step: ./run-in-bottle.sh"
