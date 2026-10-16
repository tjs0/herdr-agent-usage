#!/usr/bin/env bash
# agent-limits and tab-right against fixture Codex logs, agy cache and
# Claude metrics. No network: the agy cache is fresh, so no refresh runs.
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
bin="$here/../bin"

fail=0
check() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export XDG_CACHE_HOME="$tmp/cache" CODEX_HOME="$tmp/codex" AGY_BIN=/bin/false
now="$(date +%s)"  # resets sit 30s past a minute so the run never ticks over
in2h=$(( now + 7230 )); in3d=$(( now + 3 * 86400 + 60 ))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z; }

check "$("$bin/agent-limits" all)" "" "nothing recorded -> silent"

# Codex: newest rollout with primary limits wins; within it, the last
# valid rate_limits object (ignoring trailing null-primary premium events).
mkdir -p "$CODEX_HOME/sessions/2026/10/01"
rl() { printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"secondary":{"used_percent":%s,"window_minutes":10080,"resets_at":%s}}}}\n' "$@"; }
old="$CODEX_HOME/sessions/2026/10/01/rollout-old.jsonl"
new="$CODEX_HOME/sessions/2026/10/01/rollout-new.jsonl"
empty="$CODEX_HOME/sessions/2026/10/01/rollout-empty.jsonl"
rl 99 "$in2h" 99 "$in3d" > "$old"; touch -d '1 hour ago' "$old"
{ rl 10 "$in2h" 5 "$in3d"
  printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}\n'
  rl 66 "$in2h" 12.5 "$in3d"
  printf '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","primary":null,"secondary":null}}}\n'; } > "$new"
touch -d '10 seconds ago' "$new"
printf '{"type":"event_msg","payload":{"type":"thread_settings_applied"}}\n' > "$empty"
touch "$empty"
check "$("$bin/agent-limits" codex)" "5h 66% 2h0m  7d 12% 3d" "codex: newest file, last limits"


# agy: groups from the cached /usage reply, remaining -> used.
mkdir -p "$XDG_CACHE_HOME/agent-limits"
cat > "$XDG_CACHE_HOME/agent-limits/agy.json" <<JSON
{"command":{"data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"window":"weekly","remaining_fraction":0.978,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":0.919,"reset_time":"$(iso "$in2h")"}]},
 {"name":"Claude and GPT models","buckets":[
  {"window":"weekly","remaining_fraction":1,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":1,"reset_time":"$(iso "$in2h")"}]}]}}}
JSON
check "$("$bin/agent-limits" agy)" "5h 8% 2h0m  7d 2% 3d" "agy: gemini group only"
check "$("$bin/agent-limits" agy --3p)" "5h 0% 2h0m  7d 0% 3d" "agy --3p: claude/gpt group only"

# agy: a group past its weekly limit reports its 5h bucket as disabled, with
# no reset_time. The disabled window is left out; the group still renders.
cat > "$XDG_CACHE_HOME/agent-limits/agy.json" <<JSON
{"command":{"data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"window":"weekly","remaining_fraction":0.978,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":0.919,"reset_time":"$(iso "$in2h")"}]},
 {"name":"Claude and GPT models","buckets":[
  {"window":"weekly","remaining_fraction":0,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","disabled":true,"remaining_fraction":0}]}]}}}
JSON
check "$("$bin/agent-limits" agy --3p)" "7d 100% 3d" "agy --3p: disabled 5h bucket left out"
check "$("$bin/agent-limits" all | grep '^agy 3p')" "agy 3p               7d 100% 3d" "all: disabled 5h bucket blank"

# agy: a model group other than Gemini's and the third-party one (such as
# "Gemini 4 Argon") gets its own row, labeled by its distinguishing name, and
# stays out of both the Gemini and the --3p line.
cat > "$XDG_CACHE_HOME/agent-limits/agy.json" <<JSON
{"command":{"data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"window":"weekly","remaining_fraction":0.978,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":0.919,"reset_time":"$(iso "$in2h")"}]},
 {"name":"Claude and GPT models","buckets":[
  {"window":"weekly","remaining_fraction":1,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":1,"reset_time":"$(iso "$in2h")"}]},
 {"name":"Gemini 4 Argon","buckets":[
  {"window":"weekly","remaining_fraction":0.97,"reset_time":"$(iso "$in3d")"}]}]}}}
JSON
check "$("$bin/agent-limits" agy)" "5h 8% 2h0m  7d 2% 3d" "agy: other model groups left out"
check "$("$bin/agent-limits" agy --3p)" "5h 0% 2h0m  7d 0% 3d" "agy --3p: other model groups left out"
check "$("$bin/agent-limits" all | grep '^agy')" "$(printf '%s\n' \
  'agy        5h  8% 2h0m  7d  2% 3d' \
  'agy 3p     5h  0% 2h0m  7d  0% 3d' \
  'agy argon               7d  3% 3d')" "all: other model group on its own labeled row"

# agy: stale cache triggers detached background refresh.
touch -d '2 minutes ago' "$XDG_CACHE_HOME/agent-limits/agy.json"
fake_agy="$tmp/fake-agy"
cat > "$fake_agy" <<'SH'
#!/bin/sh
cat <<'JSON'
{"command":{"data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"window":"weekly","remaining_fraction":0.8,"reset_time":"2026-10-06T12:00:00Z"},
  {"window":"5h","remaining_fraction":0.75,"reset_time":"2026-10-03T20:00:00Z"}]}]}}}
JSON
SH
chmod +x "$fake_agy"
AGY_BIN="$fake_agy" "$bin/agent-limits" agy >/dev/null
for _ in $(seq 1 30); do
  grep -q '"remaining_fraction":0.8' "$XDG_CACHE_HOME/agent-limits/agy.json" 2>/dev/null && break
  sleep 0.1
done
check "$(jq -r '.command.data.groups[0].buckets[0].remaining_fraction' "$XDG_CACHE_HOME/agent-limits/agy.json")" "0.8" "agy: stale cache refreshes in background"
# Restore fixture cache for subsequent tests
cat > "$XDG_CACHE_HOME/agent-limits/agy.json" <<JSON
{"command":{"data":{"groups":[
 {"name":"Gemini Models","buckets":[
  {"window":"weekly","remaining_fraction":0.978,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":0.919,"reset_time":"$(iso "$in2h")"}]},
 {"name":"Claude and GPT models","buckets":[
  {"window":"weekly","remaining_fraction":1,"reset_time":"$(iso "$in3d")"},
  {"window":"5h","remaining_fraction":1,"reset_time":"$(iso "$in2h")"}]}]}}}
JSON


# Claude: the account file claude-statusline merges every session into.
cl="$XDG_CACHE_HOME/agent-limits/claude"
printf '%s\n' 13 "$in2h" 52 "$in3d" > "$cl"
check "$("$bin/agent-limits" all)" "$(printf '%s\n' \
  'claude  5h 13% 2h0m  7d 52% 3d' \
  'codex   5h 66% 2h0m  7d 12% 3d' \
  'agy     5h  8% 2h0m  7d  2% 3d' \
  'agy 3p  5h  0% 2h0m  7d  0% 3d')" "all: compact aligned table"

# all: a passed reset shows 0% with an empty countdown column, and a
# six-character countdown still lines up.
printf '%s\n' 13 "$(( now - 60 ))" 52 "$(( now + 86400 - 30 ))" > "$cl"
check "$("$bin/agent-limits" all | head -2)" "$(printf '%s\n' \
  'claude  5h  0%       7d 52% 23h59m' \
  'codex   5h 66% 2h0m  7d 12% 3d')" "all: columns widen to the widest value"
printf '%s\n' 100 "$in2h" 52 "$in3d" > "$cl"
check "$("$bin/agent-limits" all | head -2)" "$(printf '%s\n' \
  'claude  5h 100% 2h0m  7d 52% 3d' \
  'codex   5h  66% 2h0m  7d 12% 3d')" "all: 100% widens the percent column"
printf '%s\n' 13 "$in2h" 52 "$in3d" > "$cl"

# popup: sized to the watch screen. Widest line: 2 margin + 30 table columns;
# 7 lines (blank, 4 rows, blank, footer).
fake_open="$tmp/herdr-open"
printf '#!/bin/sh\necho "$*" > "%s"\n' "$tmp/open-args" > "$fake_open"; chmod +x "$fake_open"
HERDR_BIN_PATH="$fake_open" "$bin/agent-limits" popup
check "$(cat "$tmp/open-args")" "plugin pane open --plugin agent-usage --entrypoint usage --width 37 --height 10" "popup: sized to fit"

# tab-right: the focused pane's agent picks the segment.
fake="$tmp/herdr"
printf '#!/bin/sh\ncase "$3" in w2:*) a=codex ;; w3:*) a=agy ;; *) a=shell ;; esac\nprintf %s "{\\"result\\":{\\"pane\\":{\\"agent\\":\\"$a\\"}}}"\n' > "$fake"
chmod +x "$fake"
tab() { HERDR_BIN_PATH="$fake" HERDR_ACTIVE_PANE_ID="$1" "$bin/tab-right"; }
# A Claude pane (one with a metrics file) shows the account file, not the
# pane's own possibly stale snapshot.
mkdir -p "$XDG_CACHE_HOME/claude-herdr"
printf '%s\n' 40 2 "$in2h" 9 "$in3d" > "$XDG_CACHE_HOME/claude-herdr/w1:p1"
check "$(tab w1:p1)" "5h 13% 2h0m  7d 52% 3d" "tab: claude pane, no ctx"
check "$(tab w2:p1)" "5h 66% 2h0m  7d 12% 3d" "tab: codex pane"
check "$(tab w3:p1)" "5h 8% 2h0m  7d 2% 3d │ [3p] 5h 0% 2h0m  7d 0% 3d" "tab: agy pane, one line"
check "$(tab w4:p1)" "" "tab: other pane silent"

exit "$fail"
