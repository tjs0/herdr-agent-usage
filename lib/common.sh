# Shared helpers for the agent-usage scripts. Sourced, not executed.

# Human duration from NOW until EPOCH: "45m", "3h12m", "4d"; "0m" when expired.
# Days (>=24h) shown as whole days; otherwise h+m or m.
fmt_countdown() {
  local epoch="$1" now="$2" diff
  diff=$(( epoch - now ))
  if [ "$diff" -le 0 ]; then
    printf '0m'
  elif [ "$diff" -ge 86400 ]; then
    printf '%dd' "$(( diff / 86400 ))"
  elif [ "$diff" -ge 3600 ]; then
    printf '%dh%dm' "$(( diff / 3600 ))" "$(( (diff % 3600) / 60 ))"
  else
    printf '%dm' "$(( diff / 60 ))"
  fi
}

# One rate-limit window: "5h 18% 3h12m", or "5h 0%" once RESET has passed.
fmt_window() {
  local name="$1" pct="$2" reset="$3" now="$4"
  if [ -n "$reset" ] && [ "$reset" -le "$now" ]; then
    printf '%s 0%%' "$name"
  else
    printf '%s %s%% %s' "$name" "${pct%.*}" "$(fmt_countdown "${reset:-0}" "$now")"
  fi
}

# Render the status segment from raw metrics (any may be empty):
#   fmt_right CTX FIVE RESET5 SEVEN RESET7 NOW
#   -> "ctx 42%  5h 18% 3h12m  7d 61% 4d"
# Each segment shows only when its percentage is present; all empty -> nothing.
# A window whose reset has passed shows "0%": the recorded usage is stale.
fmt_right() {
  local ctx="$1" five="$2" reset5="$3" seven="$4" reset7="$5" now="$6"
  local seg=() out s
  [ -n "$ctx" ] && seg+=("ctx ${ctx%.*}%")
  [ -n "$five" ] && seg+=("$(fmt_window 5h "$five" "$reset5" "$now")")
  [ -n "$seven" ] && seg+=("$(fmt_window 7d "$seven" "$reset7" "$now")")
  [ "${#seg[@]}" -eq 0 ] && return 0
  out="${seg[0]}"
  for s in "${seg[@]:1}"; do out="$out  $s"; done
  printf '%s' "$out"
}

# Per-pane metrics file for the tab bar, written by claude-statusline:
# five lines (ctx / 5h / 5h_reset / 7d / 7d_reset), as extract_metrics prints.
herdr_metrics_file() {
  printf '%s/claude-herdr/%s' "${XDG_CACHE_HOME:-$HOME/.cache}" "$1"
}

# Account-wide Claude limits, four lines (5h / 5h_reset / 7d / 7d_reset). Every
# session's statusLine merges into it and nothing deletes it, so sessions agree
# and the numbers outlive the last session.
claude_limits_file() {
  printf '%s/agent-limits/claude' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

# One window of the merge: OLDPCT OLDRESET NEWPCT NEWRESET -> "PCT RESET".
# A session reports the limits it last saw, so an idle one reports stale usage.
# A reset over an hour later is a newer window, which wins outright; within an
# hour it is the same window, where usage only grows, so the higher one wins.
merge_window() {
  awk -v op="$1" -v or="$2" -v np="$3" -v nr="$4" 'BEGIN {
    if (np == "") { p = op; r = or }
    else if (op == "" || nr - or > 3600) { p = np; r = nr }
    else if (or - nr > 3600) { p = op; r = or }
    else { p = (np + 0 > op + 0) ? np : op; r = (nr + 0 > or + 0) ? nr : or }
    print p " " r
  }'
}

# Merge FIVE RESET5 SEVEN RESET7 into the account file under a lock and print
# the merged four lines.
merge_claude_limits() {
  local f m w5 w7
  f="$(claude_limits_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  {
    flock -w 2 9 || return 0
    m=(); [ -r "$f" ] && mapfile -t m < "$f"
    w5="$(merge_window "${m[0]:-}" "${m[1]:-}" "$1" "$2")"
    w7="$(merge_window "${m[2]:-}" "${m[3]:-}" "$3" "$4")"
    printf '%s\n' "${w5% *}" "${w5#* }" "${w7% *}" "${w7#* }" > "$f.tmp" \
      && mv -f "$f.tmp" "$f"
    cat "$f"
  } 9> "$f.lock"
}

# Read statusLine JSON on stdin, print one metric per line, in order:
#   ctx / 5h / 5h_reset / 7d / 7d_reset
# Absent fields become empty lines (positions preserved via // "").
#
# NB: one-per-line + mapfile, NOT @tsv + `read`. Tab is IFS whitespace, so
# `IFS=$'\t' read` collapses consecutive tabs and drops empty fields, which
# left-shifts a missing percentage's neighbours -- that's how reset-at epochs
# end up rendered as "5h 1781037000%". Newlines + mapfile keep positions exact.
extract_metrics() {
  jq -r '
    (.context_window.used_percentage // ""),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // "")'
}
