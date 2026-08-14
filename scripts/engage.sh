#!/usr/bin/env bash
# Spin up a real Claude Code engagement for a target app.
#
# Creates a dedicated engagement folder, seeds it with live-traffic access and
# scope/authorisation context, then starts a full Claude Code session in it -
# skills, plugins and the mp-traffic MCP all active, exactly like a normal
# session. Two modes:
#
#   engage.sh [pkg]           interactive session in a new Terminal window
#   engage.sh [pkg] --auto    headless agent that scans in the background,
#                             streaming to scan.log and writing findings/
#
# The engagement inherits the user's Claude config, so the mp-traffic MCP server
# and the mobile-pentest skill (.claude/skills/mobile-pentest, shipped with this
# repo: the methodology, the finding format, what's confirmable from traffic alone
# vs. what needs an interactive session) are both available here, plus whatever
# other security-review skills happen to be installed on this machine.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/env.sh"

MODE="interactive"
PKG=""
for a in "$@"; do
  case "$a" in
    --auto) MODE="auto" ;;
    -*) ;;
    *) PKG="$a" ;;
  esac
done
[ -z "$PKG" ] && PKG=$(grep -E '^TARGET=' "$MP_ROOT/config" 2>/dev/null | cut -d'"' -f2)
[ -z "$PKG" ] && { echo "usage: engage.sh <package> [--auto]"; exit 1; }
# PKG builds ENG (path traversal via ../ otherwise) and flows into an
# unquoted osascript heredoc via FIRST below (AppleScript/shell injection on
# the Mac otherwise, since bash expands the heredoc before osascript runs).
# Directly-runnable script, so this can't rely on bin/mp's own check.
[[ "$PKG" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || { echo "invalid package name: $PKG" >&2; exit 1; }

SCOPE=$(grep -E '^SCOPE=' "$MP_ROOT/config" 2>/dev/null | cut -d'"' -f2)
[ -n "$SCOPE" ] && ! [[ "$SCOPE" =~ ^[A-Za-z0-9_.,:-]{0,200}$ ]] && SCOPE=""
STAMP=$(date +%Y%m%d-%H%M%S)
ENG="$MP_ROOT/engagements/${PKG}_${STAMP}"
mkdir -p "$ENG/findings"

# Pin a session ID so this conversation can be picked back up later with
# `mp engage --resume <engagement-dir-name>` (or the dashboard's Sessions
# tab), same as `claude --resume <id>` would from this directory.
SID=$(uuidgen | tr '[:upper:]' '[:lower:]')
echo "$SID" > "$ENG/.session_id"
echo "$MODE" > "$ENG/.mode"

# Point the engagement at the live capture session (wherever the proxy is writing).
SESS=$(ps -eo args 2>/dev/null | grep '[m]itmdump' | tr ' ' '\n' | grep -m1 '^feedout=' | cut -d= -f2-)
[ -z "$SESS" ] && SESS=$(ls -td "$MP_LOOT"/session-*/ 2>/dev/null | head -1 | sed 's:/$::')
if [ -n "$SESS" ] && [ -d "$SESS" ]; then
  ln -sfn "$SESS" "$ENG/traffic"
  python3 "$DIR/brief.py" "$SESS" >/dev/null 2>&1
  [ -f "$SESS/BRIEF.md" ] && cp "$SESS/BRIEF.md" "$ENG/BRIEF.md"
fi

VER=$(adb -s "$MP_DEVICE" shell "dumpsys package $PKG | grep -m1 versionName" 2>/dev/null | tr -d '\r' | sed 's/.*versionName=//')

# --- engagement brief the agent reads on startup --------------------------
cat > "$ENG/CLAUDE.md" <<EOF
# Security review: $PKG

Authorised security assessment of an app you are permitted to test.
This workspace reviews HTTP traffic already captured during testing. Stay within scope.

## Target
- Package: \`$PKG\`  (version ${VER:-unknown})
- Device: MuMu emulator, Android 12 arm64, rooted, SSL-unpinned, traffic proxied
- In-scope hosts: ${SCOPE:-（scope not set - confirm before active testing）}

## Live traffic: this is your primary data source
The **mp-traffic** MCP server exposes the live capture. Re-query it as you work;
new requests appear as the app is used, so this is real-time, not a snapshot:
- \`traffic_status\`: session, flow count, hosts, per-app counts
- \`traffic_flows\`: list requests (filter by host, method, substring, unauthenticated_only)
- \`traffic_flow\`: one request in full, base64 bodies decoded
- \`traffic_search\`: search bodies/headers
- \`traffic_brief\`: the ranked brief

A snapshot is also on disk: \`./traffic/flows.jsonl\`, \`./BRIEF.md\`,
and a replay harness at \`./traffic/replay.py\` (dry-run by default; --send transmits).

## How to work
1. Load the \`mobile-pentest\` skill first. It ships with this repo and covers the
   full methodology: what's confirmable from traffic alone versus what needs an
   interactive session, the finding write-up format, and the severity rubric. Any
   other security-review skills installed on this machine can supplement it, but
   don't depend on them being present.
2. Start from \`traffic_brief\` and the highest-risk endpoints; the skill explains
   what to do with that once you have it.
3. Write findings to \`./findings/<slug>.md\` following the skill's format: evidence
   (flow #), impact, recommended fix, and whether it's confirmed or a candidate.
4. **Read-only by default.** Do not send modified requests to production without
   the operator confirming scope and blast radius. \`replay.py\` defaults to dry
   run for this reason.
5. Re-check \`traffic_flows\` periodically for new traffic and analyse it as it arrives.

## Scope discipline
Only test $PKG and its in-scope hosts. Device-wide capture may include other
apps' telemetry: ignore anything outside scope. Do not exfiltrate real user PII
seen in traffic; reference it by flow number in findings, redacted.
EOF

FIRST="Load the mobile-pentest skill first (it ships with this repo and covers the \
full methodology), then read CLAUDE.md. This is an authorised security review of \
HTTP traffic already captured from the app $PKG during testing. Using the mp-traffic \
MCP tools (traffic_brief, traffic_flows, traffic_flow, traffic_search), review the \
captured requests and responses for security weaknesses: missing or weak \
authorisation checks, sensitive data returned to the client, insecure transport or \
headers, and tokens or credentials exposed in transit. For each issue, write a \
report to findings/<slug>.md following the skill's format, with evidence (flow \
number), security impact, recommended fix, and confirmed-vs-candidate status. This \
is analysis of existing captured data only - do not send any requests. Re-check \
traffic_flows periodically as more data is captured."

echo "[*] engagement: $ENG"
echo "[*] target: $PKG   scope: ${SCOPE:-none}   traffic: ${SESS:+$(basename "$SESS")}"

if [ "$MODE" = "auto" ]; then
  echo "[*] starting headless agent (analysis-only). streaming -> $ENG/scan.log"
  # Analysis-only allowlist: live traffic + read + write findings + research +
  # skills. No Bash, no request sending - active testing stays interactive.
  #
  # --allowedTools alone is NOT a hard boundary: in headless (-p) mode with
  # no TTY to prompt, a tool call outside that list can still go through
  # instead of being denied (confirmed live - Bash executed successfully in
  # a real run despite never appearing in --allowedTools below). The actual
  # enforcement is --disallowedTools, an explicit deny that must list every
  # tool this mode is not meant to have: Bash itself, subagent/notebook/
  # slash-command tools that could reach a shell indirectly, and every
  # mp-traffic MCP tool other than the 6 read-only traffic_* ones.
  nohup claude -p "$FIRST" \
    --session-id "$SID" \
    --add-dir "$ENG" ${SESS:+--add-dir "$SESS"} \
    --permission-mode acceptEdits \
    --output-format stream-json --verbose \
    --allowedTools "mcp__mp-traffic__traffic_status" "mcp__mp-traffic__traffic_sessions" \
      "mcp__mp-traffic__traffic_flows" "mcp__mp-traffic__traffic_flow" \
      "mcp__mp-traffic__traffic_search" "mcp__mp-traffic__traffic_brief" \
      "Read" "Grep" "Glob" "Write" "Edit" "WebSearch" "WebFetch" "Skill" "TodoWrite" \
    --disallowedTools "Bash" "Task" "NotebookEdit" "SlashCommand" \
      "mcp__mp-traffic__lab_status" "mcp__mp-traffic__lab_up" "mcp__mp-traffic__lab_down" \
      "mcp__mp-traffic__lab_stop" "mcp__mp-traffic__lab_go" "mcp__mp-traffic__lab_apps" \
      "mcp__mp-traffic__lab_sessions" \
      "mcp__mp-traffic__target_set" "mcp__mp-traffic__target_switch" "mcp__mp-traffic__target_scan" \
      "mcp__mp-traffic__target_scope" "mcp__mp-traffic__target_install" "mcp__mp-traffic__target_pull" \
      "mcp__mp-traffic__target_launch" "mcp__mp-traffic__target_static" \
      "mcp__mp-traffic__bypass_list" "mcp__mp-traffic__bypass_set" "mcp__mp-traffic__bypass_reset" \
      "mcp__mp-traffic__burp_switch" "mcp__mp-traffic__burp_mitm" "mcp__mp-traffic__mobsf_start" \
      "mcp__mp-traffic__engage_start" "mcp__mp-traffic__engage_stop" "mcp__mp-traffic__engage_resume" \
      "mcp__mp-traffic__engage_findings" \
      "mcp__mp-traffic__creds_list" "mcp__mp-traffic__creds_set" "mcp__mp-traffic__creds_remove" \
      "mcp__mp-traffic__creds_send" "mcp__mp-traffic__creds_bring_front" \
    > "$ENG/scan.log" 2>&1 &
  echo $! > "$ENG/.agent.pid"
  echo "[+] agent pid $(cat "$ENG/.agent.pid")  -  tail -f $ENG/scan.log"
  echo "$ENG"
else
  # Interactive: a full session in a new Terminal window, human-driven, with
  # everything a normal `claude` invocation has.
  osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "cd '$ENG' && claude --session-id '$SID' '$FIRST'"
end tell
OSA
  echo "[+] opened an interactive Claude Code session in Terminal, in $ENG"
  echo "[*] session id: $SID  (resume later with: mp engage --resume $(basename "$ENG"))"
  echo "$ENG"
fi
