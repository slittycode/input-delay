#!/usr/bin/env bash
# Install the STAGE-2 XInput proxy for one game in one bottle.
#
# CrossOver STRIPS WINEDLLOVERRIDES from the environment (verified 2026-07-15), so the
# native-first override MUST go into the bottle registry, scoped to the game exe only:
#   HKCU\Software\Wine\AppDefaults\<GameExe.exe>\DllOverrides  xinput1_4 = native,builtin
#
# Usage:     ./install-proxy.sh "<Bottle Name>" "<dir containing game exe>" "<GameExe.exe>"
# Uninstall: ./install-proxy.sh --remove "<Bottle Name>" "<dir>" "<GameExe.exe>"
set -euo pipefail
cd "$(dirname "$0")"
WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"

if [ "${1:-}" = "--remove" ]; then
  BOTTLE="${2:?}"; DIR="${3:?}"; EXE="${4:?}"
  rm -f "$DIR/xinput1_4.dll"
  "$WINE" --bottle "$BOTTLE" reg delete "HKCU\\Software\\Wine\\AppDefaults\\$EXE\\DllOverrides" /v xinput1_4 /f 2>/dev/null || true
  echo "removed: proxy dll and registry override for $EXE"
  exit 0
fi

BOTTLE="${1:?usage: ./install-proxy.sh \"Bottle\" \"dir-with-exe\" \"GameExe.exe\"}"
DIR="${2:?usage: ./install-proxy.sh \"Bottle\" \"dir-with-exe\" \"GameExe.exe\"}"
EXE="${3:?usage: ./install-proxy.sh \"Bottle\" \"dir-with-exe\" \"GameExe.exe\"}"

[ -f xinput1_4.dll ] || ./build-proxy.sh
cp xinput1_4.dll "$DIR/"
"$WINE" --bottle "$BOTTLE" reg add "HKCU\\Software\\Wine\\AppDefaults\\$EXE\\DllOverrides" \
    /v xinput1_4 /t REG_SZ /d "native,builtin" /f 2>/dev/null
echo "installed: $DIR/xinput1_4.dll + per-app override for $EXE in bottle '$BOTTLE'"
echo "launch the game normally (CrossOver GUI is fine), run on the host:"
echo "  ../.build/release/latbudget \"<window match>\""
echo "uninstall: $0 --remove \"$BOTTLE\" \"$DIR\" \"$EXE\""
