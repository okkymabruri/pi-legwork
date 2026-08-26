#!/usr/bin/env bash
# Install/check/remove pi-legwork without creating ambient global guard links.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PI_LEGWORK_BIN_DIR:-$HOME/.local/bin}"
GLOBAL_EXT="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/extensions/damage-control.ts"
GLOBAL_RULES="$HOME/.pi/damage-control-rules.json"
LOCAL_EXT="$HERE/.pi/extensions/damage-control.ts"
MODE="${1:-install}"
case "$MODE" in install|--check|--uninstall) ;; -h|--help) sed -n '2,20p' "$0"; exit 0 ;; *) echo "unknown mode: $MODE" >&2; exit 1 ;; esac

fail=0
ok() { printf '  OK   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

if [ "$MODE" = "--uninstall" ]; then
  if [ -L "$BIN_DIR/pi-delegate" ]; then
    target="$(readlink "$BIN_DIR/pi-delegate")"
    case "$target" in "$HERE/pi-delegate.sh"|*/workflow-orchestration/code-assistant/pi/pi-delegate.sh) unlink "$BIN_DIR/pi-delegate" ;; esac
  fi
  [ ! -L "$LOCAL_EXT" ] || unlink "$LOCAL_EXT"
  [ ! -L "$GLOBAL_EXT" ] || unlink "$GLOBAL_EXT"
  [ ! -L "$GLOBAL_RULES" ] || unlink "$GLOBAL_RULES"
  echo "Removed pi-legwork links; user config and credentials were not touched."
  exit 0
fi

if [ "$MODE" = "install" ]; then
  command -v pi >/dev/null 2>&1 || { echo "pi is not on PATH" >&2; exit 1; }
  mkdir -p "$BIN_DIR" "$HERE/.pi/extensions"
  chmod +x "$HERE/pi-delegate.sh" "$HERE/install.sh"
  ln -sfn "$HERE/pi-delegate.sh" "$BIN_DIR/pi-delegate"
  ln -sfn "$HERE/extensions/damage-control.ts" "$LOCAL_EXT"
  # Legacy ambient links are dangerous outside this project. Remove only when
  # they point into this checkout; never delete a user's unrelated file.
  [ ! -L "$GLOBAL_EXT" ] || [ "$(readlink "$GLOBAL_EXT")" != "$HERE/extensions/damage-control.ts" ] || unlink "$GLOBAL_EXT"
  [ ! -L "$GLOBAL_RULES" ] || [ "$(readlink "$GLOBAL_RULES")" != "$HERE/damage-control-rules.json" ] || unlink "$GLOBAL_RULES"
fi

[ -x "$HERE/pi-delegate.sh" ] && ok "launcher executable" || bad "launcher not executable"
[ -x "$BIN_DIR/pi-delegate" ] \
  && ok "pi-delegate launcher available" || bad "pi-delegate launcher missing"
[ -L "$LOCAL_EXT" ] && [ "$(readlink "$LOCAL_EXT")" = "$HERE/extensions/damage-control.ts" ] \
  && ok "project-local Damage-Control extension" || bad "project-local extension missing or stale"
[ -f "$HERE/damage-control-rules.json" ] && ok "project-local rules" || bad "rules missing"
[ ! -e "$GLOBAL_EXT" ] && [ ! -L "$GLOBAL_EXT" ] \
  && ok "no ambient global Damage-Control extension" || bad "global extension still present: $GLOBAL_EXT"
[ ! -e "$GLOBAL_RULES" ] && [ ! -L "$GLOBAL_RULES" ] \
  && ok "no ambient global Damage-Control rules" || bad "global rules still present: $GLOBAL_RULES"
node --experimental-strip-types "$HERE/extensions/damage-control.test.ts" >/dev/null \
  && ok "Damage-Control tests" || bad "Damage-Control tests failed"

if [ "$fail" -eq 0 ]; then
  echo "Ready. Damage-Control is project-local and pi-delegate loads it explicitly."
  exit 0
fi
exit 1
