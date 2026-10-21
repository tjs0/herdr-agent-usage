#!/usr/bin/env bash
# agy-statusline against fixture payloads and a fake herdr that logs its args.
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
bin="$here/../bin"

fail=0
check() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake="$tmp/herdr"; log="$tmp/log"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$log" > "$fake"; chmod +x "$fake"

cw() { printf '{"session_id":"s1","context_window":{"context_window_size":%s,"used_percentage":%s}}' "$@"; }
out=""
run() {  # PAYLOAD [ENV...]: sets $out to the status line
  : > "$log"
  out="$(printf '%s' "$1" \
    | env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$fake" "${@:2}" "$bin/agy-statusline")"
  wait_log
}
tok() { grep -o 'ctx=[^-]*' "$log" | sed 's/ *$//'; }  # the reported token
# The report runs in the background; give it a moment to land.
wait_log() { for _ in $(seq 50); do [ -s "$log" ] && return; sleep 0.02; done; }

run "$(cw 1048576 1.4323234558105469)"; check "$(tok)" "ctx=ctx 1%" "used_percentage, floored"
check "$out" "ctx 1%" "prints the same value as the status line"
check "$(grep -c 'pane report-metadata w1:p1 --source custom:agy-metrics' "$log")" "1" "reports to the pane"
run "$(cw 1048576 99.9)"; check "$(tok)" "ctx=ctx 99%" "floors near full"
run "$(cw 1048576 0)"; check "$(tok)" "ctx=ctx 0%" "loaded session, no turns -> 0%"
run "$(cw 0 0)"; check "$(tok)" "ctx=ctx ?%" "session still loading (zero window) -> ?%"
check "$out" "ctx ?%" "status line shows ?% while loading"
run '{"cwd":"/x"}'; check "$(tok)" "ctx=ctx ?%" "no context_window -> ?%"
run 'not json'; check "$(tok)" "ctx=ctx ?%" "non-JSON stdin -> ?%"
run "$(cw 1048576 5)" HERDR_ENV=
check "$(cat "$log")" "" "outside Herdr -> no report"
check "$out" "ctx 5%" "outside Herdr still prints the status line"

exit "$fail"
