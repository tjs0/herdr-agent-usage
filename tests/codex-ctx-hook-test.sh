#!/usr/bin/env bash
# codex-ctx-hook against fixture rollouts and a fake herdr that logs its args.
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
bin="$here/../bin"

fail=0
check() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake="$tmp/herdr"; log="$tmp/log"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$log" > "$fake"; chmod +x "$fake"

tc() { printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":%s},"model_context_window":%s}}}\n' "$@"; }
run() {  # ROLLOUT [ENV...]: the token the hook reported, or nothing
  : > "$log"
  printf '{"hook_event_name":"Stop","transcript_path":"%s"}' "$1" \
    | env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$fake" "${@:2}" "$bin/codex-ctx-hook"
  grep -o 'ctx=[^-]*' "$log" | sed 's/ *$//'
}

r="$tmp/rollout.jsonl"
{ tc 50000 475000
  printf '{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{}}}\n'
  tc 25697 475000
  printf '{"type":"response_item","payload":{}}\n'; } > "$r"
check "$(run "$r")" "ctx=ctx 3%" "last token_count with info, Codex baseline"
check "$(grep -c 'pane report-metadata w1:p1 --source custom:codex-metrics' "$log")" "1" "reports to the hook's pane"

tc 12000 272000 > "$r"
check "$(run "$r")" "ctx=ctx 0%" "baseline only -> 0%"
tc 300000 272000 > "$r"
check "$(run "$r")" "ctx=ctx 100%" "over the window -> 100%"
tc 5000 8000 > "$r"
check "$(run "$r")" "ctx=ctx ?%" "window under baseline -> ?%"
printf '{"type":"response_item","payload":{}}\n' > "$r"
check "$(run "$r")" "ctx=ctx ?%" "no token_count yet (fresh or cleared session) -> ?%"
check "$(run "$tmp/missing.jsonl")" "ctx=ctx ?%" "rollout not written yet -> ?%"
tc 25697 475000 > "$r"
check "$(run "$r" HERDR_ENV=)" "" "outside Herdr -> silent"
check "$(printf '{"transcript_path":"%s"}' "$r" | HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_BIN_PATH="$fake" "$bin/codex-ctx-hook"; echo "exit $?")" "exit 0" "prints nothing, exits 0"

exit "$fail"
