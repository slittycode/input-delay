#!/usr/bin/env bash
set -euo pipefail

# ── Master verification chain: controller input at every layer ───────────────
# Tests the full path from hardware to CrossOver bottle and reports pass/fail
# at each layer.
#
# Usage:
#   ./verify-all.sh [--bottle <name>]
#
# If --bottle is omitted, only layers 1-3 (native) are checked.

BOTTLE_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bottle) BOTTLE_NAME="$2"; shift 2 ;;
        *) echo "Usage: $0 [--bottle <name>]"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CX_WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"

PASS=0
FAIL=0
SKIP=0
MANUAL=0

RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()   { PASS=$((PASS+1)); echo -e "  ${GREEN}[PASS]${NC} $*"; }
fail()   { FAIL=$((FAIL+1)); echo -e "  ${RED}[FAIL]${NC} $*"; }
skip()   { SKIP=$((SKIP+1)); echo -e "  ${YELLOW}[SKIP]${NC} $*"; }
manual() { MANUAL=$((MANUAL+1));
    echo -e "  ${CYAN}[MANUAL]${NC} $*"; echo -e "      $2"; }

header() { echo -e "\n${BOLD}══ $* ══${NC}\n"; }

# ═══════════════════════════════════════════════════════════════════════════════
# LAYER 1 — Physical connection
# ═══════════════════════════════════════════════════════════════════════════════

header "LAYER 1 — Physical Connection"

# Check Bluetooth for Xbox controller
BT_INFO=$(system_profiler SPBluetoothDataType 2>/dev/null || echo "")
if echo "$BT_INFO" | grep -qi "xbox"; then
    NAME=$(echo "$BT_INFO" | grep -B1 -i "xbox" | head -1 | sed 's/^[[:space:]]*//')
    STATUS=$(echo "$BT_INFO" | grep -A5 -i "xbox" | grep "Connected:" | head -1 |
             sed 's/^[[:space:]]*//')
    pass "Xbox controller found: $NAME — ${STATUS:-status unknown}"
elif echo "$BT_INFO" | grep -qi "wireless controller\|ps4\|dualshock\|gamepad"; then
    NAME=$(echo "$BT_INFO" | grep -i "wireless controller\|ps4\|dualshock\|gamepad" |
           head -1 | sed 's/^[[:space:]]*//')
    pass "Controller found: $NAME"
else
    # Fallback: check USB
    USB_INFO=$(system_profiler SPUSBDataType 2>/dev/null || echo "")
    if echo "$USB_INFO" | grep -qi "xbox\|gamepad\|controller\|joystick"; then
        pass "Controller found via USB (check $USB_INFO for details)"
    else
        fail "No Xbox/controller found in Bluetooth or USB."
        fail "  Confirm controller is powered on and paired."
        fail "  macOS: System Settings → Bluetooth → look for Xbox Wireless Controller"
        false
    fi
fi >> "$RESULT_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# LAYER 2 — OS HID level (manual — browser)
# ═══════════════════════════════════════════════════════════════════════════════

header "LAYER 2 — OS HID Framework (Browser test)"

manual "Open https://gamepad-tester.com in Safari or Chrome." \
       "Move sticks and press buttons on your controller."
manual "  If the bars/buttons respond: Layer 2 = PASS. Apple's framework delivers data." \
       "  If nothing responds: controller not reaching macOS HID layer."
manual "Press 'y' then Enter if it worked, anything else if not: " ""
read -r ANSWER </dev/tty
if [[ "$ANSWER" == "y" ]]; then
    pass "gamepad-tester.com shows live controller data — Apple GameController framework OK"
else
    fail "gamepad-tester.com shows no response — controller not reaching macOS HID layer."
    fail "  Check: is the controller paired and powered? (Bluetooth battery low?)"
    fail "  Try: restart Bluetooth, re-pair, connect via USB"
fi >> "$RESULT_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# LAYER 3 — pygame/SDL (native)
# ═══════════════════════════════════════════════════════════════════════════════

header "LAYER 3 — pygame/SDL (Native)"

GAMEPADLA_DIR="$SCRIPT_DIR/gamepadla-plus"
if [[ ! -d "$GAMEPADLA_DIR" ]]; then
    skip "gamepadla-plus directory not found at $GAMEPADLA_DIR"
else
    echo "  Checking controller enumeration..."
    ENUM_OUTPUT=$("$GAMEPADLA_DIR/.venv/bin/python" -c "
import pygame
pygame.init()
pygame.joystick.init()
c = pygame.joystick.get_count()
print(f'Controllers: {c}')
for i in range(c):
    j = pygame.joystick.Joystick(i)
    j.init()
    print(f'  [{i}] {j.get_name()}  axes={j.get_numaxes()} btns={j.get_numbuttons()}')
" 2>&1) || ENUM_OUTPUT="ERROR: $ENUM_OUTPUT"

    if echo "$ENUM_OUTPUT" | grep -q "Controllers: [1-9]"; then
        echo "  $ENUM_OUTPUT" | sed 's/^/  /'
        pass "pygame enumerates the controller."
    else
        echo "  $ENUM_OUTPUT" | sed 's/^/  /'
        fail "pygame found 0 controllers. Controller enumerated as 'Xbox Series X Controller'"
        fail "  but SDL/pygame can't access it — known Stage 1 blocker."
        fail "  The games are: (a) macOS GameController framework claims the device exclusively,"
        fail "  or (b) this terminal context doesn't receive input events."
    fi

    echo ""
    echo "  Now running live input test (6 seconds) — MOVE STICKS + PRESS BUTTONS..."

    LIVE_OUTPUT=$(cd "$GAMEPADLA_DIR" && uv run python diag_axes2.py 6 2>&1) || true

    echo ""
    echo "  Live test output (last 3 lines):"
    echo "$LIVE_OUTPUT" | tail -3 | sed 's/^/    /'
    echo ""

    AXIS_SUM=$(echo "$LIVE_OUTPUT" | grep "TOTAL" | grep -oP 'axis-changes=\[\K[^\]]+' |
               tr ',' '+' | bc 2>/dev/null || echo "0")
    BTN_SUM=$(echo "$LIVE_OUTPUT" | grep "TOTAL" | grep -oP 'button-events=\K\d+' || echo "0")

    if [[ "$AXIS_SUM" -gt 10 ]] || [[ "$BTN_SUM" -gt 0 ]]; then
        pass "LIVE input detected: $AXIS_SUM axis changes, $BTN_SUM button events"
    elif [[ "$AXIS_SUM" -gt 0 ]]; then
        echo "  Only $AXIS_SUM axis changes — may be drift/noise. Try moving more aggressively."
        pass "Some input detected ($AXIS_SUM axis changes)"
    else
        fail "Zero input changes in 6 seconds. Stage 1 blocker confirmed."
        fail "  See NOTES.md for root cause analysis."
    fi
fi >> "$RESULT_FILE"

# ═══════════════════════════════════════════════════════════════════════════════
# BOTTLE LAYER 1 — Wine device detection
# ═══════════════════════════════════════════════════════════════════════════════

if [[ -n "$BOTTLE_NAME" ]]; then
    BOTTLE_DIR="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE_NAME"
    PROBE_EXE_HOST="$SCRIPT_DIR/cross-over/probe_controller.exe"
    PROBE_EXE_BOTTLE="C:\\polling\\probe_controller.exe"
    PROBE_EXE_BOTTLE_PATH="$BOTTLE_DIR/drive_c/polling/probe_controller.exe"

    header "BOTTLE LAYER 1 — Wine XInput Device Detection"

    if [[ ! -d "$BOTTLE_DIR" ]]; then
        fail "Bottle '$BOTTLE_NAME' not found at: $BOTTLE_DIR"
        fail "  Create it via CrossOver GUI: Bottle → New Bottle → Windows 10"
    elif [[ ! -f "$PROBE_EXE_HOST" ]]; then
        skip "probe_controller.exe not found at $PROBE_EXE_HOST"
        skip "  Compile it: cd cross-over && x86_64-w64-mingw32-gcc -O2 -o probe_controller.exe probe_controller.c"
    else
        export WINEPREFIX="$BOTTLE_DIR"

        mkdir -p "$BOTTLE_DIR/drive_c/polling"
        cp "$PROBE_EXE_HOST" "$PROBE_EXE_BOTTLE_PATH"

        echo "  Running standalone XInput probe (18KB, zero dependencies)..."
        echo ""

        PROBE_OUTPUT=$(WINEDEBUG="-all" "$CX_WINE" "$PROBE_EXE_BOTTLE" 2>/dev/null) || PROBE_RC=$?

        echo "$PROBE_OUTPUT" | sed 's/^/  /'

        if echo "$PROBE_OUTPUT" | grep -q "LIVE: axis/button values changed"; then
            pass "XInput: controller found AND live data flowing inside Wine"
        elif echo "$PROBE_OUTPUT" | grep -q "CONNECTED"; then
            pass "XInput: controller detected in bottle"
            warn "  But live data not confirmed — move stick and re-run probe for pass."
        elif echo "$PROBE_OUTPUT" | grep -q "No controller found"; then
            fail "Wine XInput: no controller detected in any player slot (0-3)"
            fail "  Wine on macOS may not have gamepad HID passthrough."
            fail "  Try: USB connection, re-pair, or different Wine version."
        else
            fail "Probe produced unexpected output (check above)."
        fi
    fi

    # ═══════════════════════════════════════════════════════════════════════════════
    # BOTTLE LAYER 2 — Live data inside Wine
    # ═══════════════════════════════════════════════════════════════════════════════

    header "BOTTLE LAYER 2 — Live Polling Inside Wine"

    if [[ -f "$BOTTLE_DIR/drive_c/polling/Polling.exe" ]]; then
        manual "Launch Polling.exe inside the bottle:" \
               "export WINEPREFIX=\"$BOTTLE_DIR\""
        manual "WINEDEBUG=+dinput,+hid,+xinput,+timestamp \\" \
               "\"$CX_WINE\" \"C:\\polling\\Polling.exe\" 2> wine-debug.log"
        manual "In the Polling CLI:" \
               "  1. Does it list the controller? → bottle can see it"
        manual "  2. If you select controller + Left stick + rotate:" \
               "  do changing ms values appear? → live data flows"
        manual "Press 'y' if changing ms values appeared, anything else if not: " ""
        read -r WINE_OK </dev/tty
        if [[ "$WINE_OK" == "y" ]]; then
            pass "Polling.exe shows changing ms values — live controller data inside Wine"
        else
            fail "Controller data not flowing inside Wine."
            fail "  Check wine-debug.log for dinput/hid errors."
        fi
    else
        skip "Polling.exe not found in bottle."
        skip "  Run ./cross-over/install-polling.sh or manually download to:"
        skip "  $BOTTLE_DIR/drive_c/polling/Polling.exe"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL + SKIP + MANUAL))
header "RESULTS (${TOTAL} checks)"
echo -e "${GREEN}  PASS:   $PASS${NC}"
echo -e "${RED}  FAIL:   $FAIL${NC}"
echo -e "${YELLOW}  SKIP:   $SKIP${NC}"
echo -e "${CYAN}  MANUAL: $MANUAL${NC}"

if [[ "$FAIL" -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}✅ All checks passed. The controller input path is verified.${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Run the native polling test:"
    echo "     cd gamepadla-plus && uv run gamepadla test --stick left --samples 2000"
    echo ""
    echo "  2. Run the in-bottle polling test:"
    echo "     ./cross-over/run-in-bottle.sh"
    echo ""
    echo "  3. Compare results:"
    echo "     ./cross-over/run-comparison.sh"
else
    echo ""
    echo -e "${RED}❌ ${FAIL} check(s) failed. Resolve failures above, then re-run.${NC}"
    echo ""
    echo "Common fixes:"
    echo "  - Power cycle the controller (hold Xbox/PS button 10s, re-pair)"
    echo "  - Switch between Bluetooth and USB"
fi
