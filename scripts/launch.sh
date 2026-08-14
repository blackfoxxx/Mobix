#!/usr/bin/env bash
# Launch an app with the full bypass chain, DETACHED - no terminal to keep open.
#
#   launch.sh <package>            spawn cold with bypasses  (use this)
#   launch.sh <package> --attach   attach to an already-running process
#   launch.sh --stop               end the held session
#   launch.sh --log                follow the hook log
#
# Root-detection bypass lives in this chain, so apps that refuse to run on a
# rooted device MUST be started this way. Tapping the launcher icon starts
# them unhooked and they will show "Rooted device detected".
#
# Implementation note: this drives the frida CLI rather than the Python
# bindings. Since Frida 17 the `Java` global comes from frida-java-bridge, which
# the CLI injects and a raw create_script() does not - bindings give
# "ReferenceError: 'Java' is not defined". Piping from `tail -f /dev/null`
# gives the CLI a stdin that never reaches EOF, so its session stays alive
# without a TTY.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/env.sh"

PIDF="$MP_ROOT/.launch.pid"
LOGF="$MP_LOOT/launch.log"
S="$MP_FRIDA_SCRIPTS"

case "${1:-}" in
  --stop)
    if [ -f "$PIDF" ]; then pkill -P "$(cat "$PIDF")" 2>/dev/null; kill "$(cat "$PIDF")" 2>/dev/null; fi
    pkill -f "frida -U -f " 2>/dev/null
    rm -f "$PIDF" "$MP_ROOT/.active-app"; echo "stopped"; exit 0 ;;
  --log) exec tail -f "$LOGF" ;;
esac

PKG="${1:?usage: launch.sh <package> [--attach] | --stop | --log}"; shift || true
# Interpolated into `adb shell "...$PKG..."` below - the DEVICE's shell
# parses that string, so an unvalidated PKG is command injection on the
# device (root adbd on this lab). Directly-runnable script, so this check
# can't rely on bin/mp having already validated its argument.
[[ "$PKG" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || { echo "invalid package name: $PKG" >&2; exit 1; }
MODE="-f"
for a in "$@"; do [ "$a" = "--attach" ] && MODE="-n"; done
mkdir -p "$MP_LOOT"

# One held session at a time, else two spawns fight over the process.
if [ -f "$PIDF" ]; then pkill -P "$(cat "$PIDF")" 2>/dev/null; kill "$(cat "$PIDF")" 2>/dev/null; sleep 1; fi
pkill -f "frida -U -f " 2>/dev/null
[ "$MODE" = "-f" ] && adb -s "$MP_DEVICE" shell "am force-stop $PKG" >/dev/null 2>&1
sleep 3

# Stop the previously hooked app (if different) so it stops phoning home -
# otherwise its background traffic lands in this session, device-wide capture
# tags it as the NEW app, and it looks like "the traffic didn't change".
PREV=$(cat "$MP_ROOT/.active-app" 2>/dev/null)
if [ -n "$PREV" ] && [ "$PREV" != "$PKG" ]; then
  echo "[*] stopping previously hooked app: $PREV"
  adb -s "$MP_DEVICE" shell "am force-stop $PREV" >/dev/null 2>&1
fi

# Which bypass modules load is selectable (bypass.json, or the dashboard), so
# ask bypass.py for the -l flags instead of hardcoding the chain here. It also
# pushes the per-module anti-detection choices into config.js as a side effect.
BYPASS_ARGS=$(python3 "$DIR/bypass.py" --args 2>/dev/null | tail -1)
if [ -z "$BYPASS_ARGS" ]; then
  echo "[!] bypass.py failed - falling back to the full chain"
  BYPASS_ARGS="-l '$S/config.js' -l '$S/android-proxy-override.js' \
-l '$S/android-system-certificate-injection.js' -l '$S/android-certificate-unpinning.js' \
-l '$S/android-certificate-unpinning-fallback.js' -l '$S/android-disable-root-detection.js' \
-l '$S/android-anti-detection.js' -l '$S/android-facetec-init-bypass.js'"
fi

# Spawning under the full hook chain occasionally loses a race and the app dies
# with "Process crashed: Bad access due to invalid address". It is not
# deterministic - a retry almost always succeeds - so retry once rather than
# reporting a failure the user would just work around by hand.
attempt=1
while [ "$attempt" -le 2 ]; do
  nohup sh -c "tail -f /dev/null | frida -U $MODE '$PKG' $BYPASS_ARGS" > "$LOGF" 2>&1 &
  echo $! > "$PIDF"
  sleep 20
  if pgrep -f "frida -U $MODE $PKG" >/dev/null 2>&1 && ! grep -q "Process crashed" "$LOGF"; then
    break
  fi
  if [ "$attempt" -eq 1 ]; then
    echo "[*] spawn lost a race (app crashed on startup) - retrying once"
    pkill -P "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
    kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
    pkill -f "frida -U -f " 2>/dev/null
    adb -s "$MP_DEVICE" shell "am force-stop $PKG" >/dev/null 2>&1
    sleep 4
  fi
  attempt=$((attempt+1))
done

if pgrep -f "frida -U $MODE $PKG" >/dev/null 2>&1; then
  # Only now, confirmed hooked - not up front - so a failed launch never
  # leaves .active-app (and therefore `mp status`'s "hooks" reading) claiming
  # a package is hooked when nothing actually is.
  echo "$PKG" > "$MP_ROOT/.active-app"
  echo "[+] $PKG running with bypasses active - use the app normally."
  printf "    root checks blocked: %s\n" "$(grep -c 'Blocked possible root detection' "$LOGF")"
  grep -qE "Certificate unpinning completed" "$LOGF" && echo "    SSL unpinning:       active"
  grep -qE "Proxy configuration overridden" "$LOGF" && echo "    proxy override:      ${MP_PROXY_HOST}:${MP_PROXY_PORT}"
  echo "    log:  $DIR/launch.sh --log"
  echo "    stop: $DIR/launch.sh --stop"
else
  # A failed spawn can leave frida hung at its own interactive prompt (stdin
  # is `tail -f /dev/null`, which never closes, so it never gets EOF and
  # never exits on its own) rather than actually terminating - confirmed live:
  # the wrapper process survives well after this script exits, and its
  # command line still contains "frida -U -f '<pkg>'" as text, so it keeps
  # matching every `pgrep -f 'frida -U -[fn] '` health check downstream
  # (`mp status`, the dashboard, MCP lab_status) into falsely reporting
  # "hooks: held" for a launch that never actually worked. Leave nothing
  # alive behind a reported failure.
  pkill -P "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
  kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
  pkill -f "frida -U $MODE '$PKG'" 2>/dev/null
  rm -f "$PIDF" "$MP_ROOT/.active-app"
  echo "[!] session did not hold:"; tail -20 "$LOGF"; exit 1
fi
