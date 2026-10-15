#!/usr/bin/env bash
# Run every tests/*-test.sh; exit nonzero if any fails.
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
rc=0
for t in "$here"/*-test.sh; do
  echo "== $(basename "$t")"
  timeout 120 bash "$t" || { echo "FAILED: $(basename "$t")"; rc=1; }
done
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit "$rc"
