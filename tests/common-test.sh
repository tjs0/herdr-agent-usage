#!/usr/bin/env bash
# Unit tests for lib/common.sh helpers and the Claude scripts.
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
source "$here/../lib/common.sh"

fail=0
check() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

# fmt_countdown EPOCH NOW  (NOW fixed at 1000000)
check "$(fmt_countdown 1000000 1000000)" "0m"    "now -> 0m"
check "$(fmt_countdown 999000  1000000)" "0m"    "past -> 0m"
check "$(fmt_countdown 1002700 1000000)" "45m"   "45 min"
check "$(fmt_countdown 1011520 1000000)" "3h12m" "3h12m"
check "$(fmt_countdown 1345600 1000000)" "4d"    "4 days"
check "$(fmt_countdown 1003600 1000000)" "1h0m"  "exactly 1h"
check "$(fmt_countdown 1086400 1000000)" "1d"    "exactly 1 day"

# extract_metrics: ctx,5h,5h_reset,7d,7d_reset, one per line, from stdin JSON.
# (Newline-separated, NOT @tsv -- empty fields must keep their position; see the
# helper's comment for why tabs would left-shift a missing percentage's reset.)
full='{"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":18,"resets_at":1738425600},"seven_day":{"used_percentage":61,"resets_at":1738857600}}}'
check "$(printf '%s' "$full" | extract_metrics)" "$(printf '42\n18\n1738425600\n61\n1738857600')" "full metrics"

nolim='{"context_window":{"used_percentage":42}}'
check "$(printf '%s' "$nolim" | extract_metrics)" "$(printf '42\n\n\n\n')" "no rate_limits -> ctx only"

one='{"context_window":{"used_percentage":7},"rate_limits":{"five_hour":{"used_percentage":3,"resets_at":111}}}'
check "$(printf '%s' "$one" | extract_metrics)" "$(printf '7\n3\n111\n\n')" "partial rate_limits"

# fmt_right CTX FIVE RESET5 SEVEN RESET7 NOW  (NOW fixed at 1000000)
check "$(fmt_right 42.7 18 1011520 61 1345600 1000000)" "ctx 42%  5h 18% 3h12m  7d 61% 4d" "fmt_right full"
check "$(fmt_right 42 '' '' '' '' 1000000)" "ctx 42%" "fmt_right ctx only"
check "$(fmt_right '' 18 1002700 '' '' 1000000)" "5h 18% 45m" "fmt_right 5h only"
check "$(fmt_right '' '' '' '' '' 1000000)" "" "fmt_right nothing"
check "$(fmt_right '' 18 999000 61 1345600 1000000)" "5h 0%  7d 61% 4d" "fmt_right expired window -> 0%"

# merge_window OLDPCT OLDRESET NEWPCT NEWRESET -> "PCT RESET". A reset over an
# hour later is a new window; within an hour it is the same window, where usage
# only grows, so the higher percentage wins whichever session reports it.
check "$(merge_window '' '' 18 5000)"      "18 5000" "merge: nothing stored -> new"
check "$(merge_window 18 5000 '' '')"      "18 5000" "merge: no new window -> keep"
check "$(merge_window 30 5000 18 5000)"    "30 5000" "merge: stale lower report loses"
check "$(merge_window 18 5000 30.5 5001)"  "30.5 5001" "merge: higher report wins"
check "$(merge_window 90 5000 2 23000)"    "2 23000" "merge: later window wins"
check "$(merge_window 2 23000 90 5000)"    "2 23000" "merge: earlier window loses"

# herdr-tab-right: a Claude pane (one with a metrics file) renders the account
# file; silent without a pane file.
cache="$(mktemp -d)"
export XDG_CACHE_HOME="$cache"
mkdir -p "$cache/claude-herdr" "$cache/agent-limits"
printf '%s\n' 42 18 "$(( $(date +%s) + 7230 ))" '' '' > "$cache/claude-herdr/w1:p2"
printf '%s\n' 25 "$(( $(date +%s) + 7230 ))" '' '' > "$cache/agent-limits/claude"
check "$(HERDR_ACTIVE_PANE_ID=w1:p2 "$here/../bin/tab-right")" "5h 25% 2h0m" "herdr-right renders account file, no ctx"
rm "$cache/agent-limits/claude"
check "$(HERDR_ACTIVE_PANE_ID=w1:p3 "$here/../bin/tab-right")" "" "herdr-right silent without file"

# claude-statusline inside Herdr writes the file; SessionEnd removes it.
json='{"context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":18,"resets_at":111}}}'
line="$(printf '%s' "$json" | env HERDR_ENV=1 HERDR_PANE_ID=w2:p1 HERDR_BIN_PATH=/bin/true \
  "$here/../bin/claude-statusline")"
check "$line" "ctx 42%  5h 18%" "status prints in-Claude line inside Herdr"
check "$(cat "$cache/claude-herdr/w2:p1")" "$(printf '42\n18\n111\n\n')" "status writes herdr metrics file"
check "$(cat "$cache/agent-limits/claude")" "$(printf '18\n111\n\n')" "status writes account file"
# A second session with older numbers for the same window: the account file
# and its in-Claude line keep the higher usage, and fill in its 7d window.
json='{"context_window":{"used_percentage":5},"rate_limits":{"five_hour":{"used_percentage":9,"resets_at":111},"seven_day":{"used_percentage":40,"resets_at":222}}}'
line="$(printf '%s' "$json" | env -u HERDR_ENV "$here/../bin/claude-statusline")"
check "$line" "ctx 5%  5h 18%  7d 40%" "status line shows merged account usage"
check "$(cat "$cache/agent-limits/claude")" "$(printf '18\n111\n40\n222')" "status merges into account file"
# A fresh or /clear'ed session has no used_percentage yet: report "ctx ?%" so
# the sidebar drops the previous session's value.
fake="$cache/herdr"; printf '#!/bin/sh\necho "$*" >> "%s"\n' "$cache/herdr.log" > "$fake"; chmod +x "$fake"
printf '%s' '{"context_window":{"used_percentage":null}}' | env HERDR_ENV=1 HERDR_PANE_ID=w2:p1 \
  HERDR_BIN_PATH="$fake" "$here/../bin/claude-statusline" > /dev/null
sleep 0.3
check "$(grep -o 'ctx=[^-]*' "$cache/herdr.log" | sed 's/ *$//')" "ctx=ctx ?%" "status reports ctx ?% without a percentage"
env HERDR_PANE_ID=w2:p1 "$here/../bin/claude-session-end" < /dev/null
check "$(test -e "$cache/claude-herdr/w2:p1" && echo yes || echo no)" "no" "SessionEnd removes herdr metrics file"
check "$(test -e "$cache/agent-limits/claude" && echo yes || echo no)" "yes" "SessionEnd keeps account file"
rm -rf "$cache"; unset XDG_CACHE_HOME

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$fail"
