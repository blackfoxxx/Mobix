#!/usr/bin/env bash
# mp-mcp over HTTP: for reaching the MCP control plane through a tunnel you
# run yourself (cloudflared/ngrok/tailscale funnel) instead of local stdio -
# see the README's "Remote MCP access" section before exposing this.
# Usage: mcp-http.sh [start|stop|status]
set -uo pipefail
. "$(dirname "$0")/env.sh"
PORT="${MP_MCP_PORT:-8799}"
PIDFILE="$MP_ROOT/.mcp_http.pid"
LOGFILE="$MP_ROOT/.mcp_http.log"
TOKENFILE="$MP_ROOT/.mcp_http_token"

running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "${1:-status}" in
  start)
    if running; then
      echo "[*] already running (pid $(cat "$PIDFILE"))"
    else
      nohup "$MP_ROOT/bin/mp-mcp" --http --port "$PORT" > "$LOGFILE" 2>&1 &
      echo $! > "$PIDFILE"
      sleep 1
      running || { echo "[-] failed to start - see $LOGFILE" >&2; exit 1; }
    fi
    echo "[*] listening on http://127.0.0.1:$PORT/mcp (localhost only)"
    [ -f "$TOKENFILE" ] && echo "[*] bearer token: $(cat "$TOKENFILE")"
    echo "[*] put a tunnel in front of it to reach it remotely, e.g.:"
    echo "      cloudflared tunnel --url http://127.0.0.1:$PORT"
    echo "      ngrok http $PORT"
    echo "      tailscale funnel $PORT"
    ;;
  stop)
    if running; then
      kill "$(cat "$PIDFILE")" 2>/dev/null
      echo "[+] stopped"
    else
      echo "[*] not running"
    fi
    rm -f "$PIDFILE"
    ;;
  status)
    if running; then
      echo "[*] running (pid $(cat "$PIDFILE")) on http://127.0.0.1:$PORT/mcp"
      [ -f "$TOKENFILE" ] && echo "[*] bearer token: $(cat "$TOKENFILE")"
    else
      echo "[*] not running"
    fi
    ;;
  *) echo "usage: mcp-http.sh [start|stop|status]"; exit 1 ;;
esac
