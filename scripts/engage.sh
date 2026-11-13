#!/usr/bin/env bash
# Spin up a real AI-agent engagement for a target app.
#
# Creates a dedicated engagement folder, seeds it with live-traffic access and
# scope/authorisation context, then starts a full agent session in it - skills,
# MCP and the chosen tool's own permissions all active. Two modes, and a
# choice of underlying CLI:
#
#   engage.sh [pkg]                      interactive session in a new Terminal window
#   engage.sh [pkg] --auto               headless agent, streaming to scan.log
#   engage.sh [pkg] --tool opencode       use OpenCode instead of Claude Code
#   engage.sh [pkg] --tool codex          use Codex CLI instead of Claude Code
#
# --tool defaults to AGENT_TOOL in config, or "claude" if unset. All three
# read the same per-engagement CLAUDE.md and the same methodology (Claude
# Code and OpenCode both load .claude/skills/mobile-pentest/ - OpenCode
# auto-loads Claude Code skills natively; Codex loads the vendor-neutral copy
# at .agents/skills/mobile-pentest/), so the methodology and finding format
# are identical regardless of which CLI drives the session.
#
# --tool codex is INTERACTIVE ONLY. Claude Code's and OpenCode's --auto mode
# both get a hard, verified boundary: an explicit tool-level deny list (see
# the --disallowedTools comment below), so the headless agent literally
# cannot invoke Bash or any mutating tool. Codex CLI has no per-tool
# allow/deny of that kind - its only knob is a coarser --sandbox (filesystem
# + network scope), and that boundary has NOT been empirically verified live
# in this lab. Rather than give --auto a different, weaker meaning depending
# on --tool, Codex is interactive-only (a human is present for every
# command) until that's actually confirmed.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/env.sh"

MODE="interactive"
TOOL=""
PKG=""
prev=""
for a in "$@"; do
  case "$a" in
    --auto) MODE="auto" ;;
    --tool) prev="tool" ;;
    -*) ;;
    *)
      if [ "$prev" = "tool" ]; then TOOL="$a"; prev=""; else PKG="$a"; fi
      ;;
  esac
done
[ -z "$TOOL" ] && TOOL=$(grep -E '^AGENT_TOOL=' "$MP_ROOT/config" 2>/dev/null | cut -d'"' -f2)
[ -z "$TOOL" ] && TOOL="claude"
[[ "$TOOL" =~ ^(claude|opencode|codex)$ ]] || { echo "unknown --tool: $TOOL (expected: claude, opencode, codex)" >&2; exit 1; }
[ -z "$PKG" ] && PKG=$(grep -E '^TARGET=' "$MP_ROOT/config" 2>/dev/null | cut -d'"' -f2)
[ -z "$PKG" ] && { echo "usage: engage.sh <package> [--auto] [--tool claude|opencode|codex]"; exit 1; }
[ "$TOOL" = "codex" ] && [ "$MODE" = "auto" ] && { echo "--tool codex is interactive-only for now: its --auto boundary isn't a verified tool-ACL like claude/opencode's (see the comment at the top of this file). Drop --auto, or use --tool claude/opencode." >&2; exit 1; }
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
echo "$TOOL" > "$ENG/.tool"

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
echo "[*] target: $PKG   scope: ${SCOPE:-none}   traffic: ${SESS:+$(basename "$SESS")}   tool: $TOOL"

# $FIRST is free text (this lab's own wording, edited over time) that ends up
# embedded in a generated shell command - for interactive mode that command
# itself sits inside an AppleScript string, two layers of quoting. A single
# apostrophe anywhere in $FIRST (e.g. "the skill's format", a real wording
# choice made in this file) closes a naively-embedded single-quoted argument
# early and leaves Terminal's shell hung at a continuation prompt waiting for
# a quote that never comes - confirmed live, not hypothetical, and the reason
# every interactive branch below routes the prompt through a file instead of
# inlining it: `"$(cat ...)"` reproduces the file's content as a single
# argument no matter what quote characters it contains.
printf '%s' "$FIRST" > "$ENG/.first_prompt"

if [ "$TOOL" = "opencode" ]; then
  if [ "$MODE" = "auto" ]; then
    echo "[*] starting headless OpenCode agent (analysis-only). streaming -> $ENG/scan.log"
    # mobix-auto (.opencode/agent/mobix-auto.md, shipped with this repo) is the
    # OpenCode equivalent of the --disallowedTools boundary above: Bash and
    # every non-traffic mp-traffic tool are set to `deny` in its permission
    # block, verified live the same way - forceful, explicit instructions to
    # invoke bash produced zero tool-call attempts across repeated trials,
    # and --auto (OpenCode's own "approve anything not explicitly denied"
    # flag) does not loosen an explicit deny either.
    nohup opencode run --agent mobix-auto --dir "$ENG" \
      --format json \
      "$(cat "$ENG/.first_prompt")" \
      > "$ENG/scan.log" 2>&1 &
    echo $! > "$ENG/.agent.pid"
    echo "[+] agent pid $(cat "$ENG/.agent.pid")  -  tail -f $ENG/scan.log"
    echo "$ENG"
  else
    osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "cd '$ENG' && opencode --agent mobix-interactive --prompt \"\$(cat '$ENG/.first_prompt')\""
end tell
OSA
    echo "[+] opened an interactive OpenCode session in Terminal, in $ENG"
    echo "$ENG"
  fi
  exit 0
fi

if [ "$TOOL" = "codex" ]; then
  # MODE can't be "auto" here - rejected above with an explanatory error.
  # Wire the MCP server in for this invocation only, via -c, rather than
  # `codex mcp add` (which writes into the user's own ~/.codex/config.toml
  # globally and permanently). The value is a bare path with no TOML special
  # characters, so it deliberately isn't quoted: -c's value is parsed as TOML
  # first and falls back to using the raw string as a literal on parse
  # failure (an unquoted `/...` path isn't valid TOML), which sidesteps the
  # apostrophe/quote-nesting problem above entirely rather than fighting it.
  osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
  activate
  do script "cd '$ENG' && codex -c mcp_servers.mp-traffic.command=$MP_ROOT/bin/mp-mcp \"\$(cat '$ENG/.first_prompt')\""
end tell
OSA
  echo "[+] opened an interactive Codex session in Terminal, in $ENG"
  echo "$ENG"
  exit 0
fi

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
  do script "cd '$ENG' && claude --session-id '$SID' \"\$(cat '$ENG/.first_prompt')\""
end tell
OSA
  echo "[+] opened an interactive Claude Code session in Terminal, in $ENG"
  echo "[*] session id: $SID  (resume later with: mp engage --resume $(basename "$ENG"))"
  echo "$ENG"
fi
