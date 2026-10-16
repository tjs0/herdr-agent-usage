#!/usr/bin/env bash
# Manifest and link-bin: every command names a script that exists relative to
# the plugin root, none reaches into $HOME, and link-bin makes a stable path.
set -uo pipefail
here="$(dirname "$(readlink -f "$0")")"
root="$here/.."

fail=0
check() { if [ "$1" = "$2" ]; then echo "ok: $3"; else echo "FAIL: $3 (got '$1', want '$2')"; fail=1; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Each command's script (argv[1] after the interpreter), one per line.
scripts="$(python3 -I - "$root/herdr-plugin.toml" <<'PY'
import sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
for sec in ("actions", "panes", "startup"):
    for e in m.get(sec, []):
        print(e["command"][1])
        assert "$HOME" not in " ".join(e["command"]), e
PY
)"
check "$?" "0" "manifest parses, no \$HOME in commands"
missing=""
while IFS= read -r s; do [ -x "$root/$s" ] || [ -f "$root/$s" ] || missing="$missing $s"; done <<< "$scripts"
check "$missing" "" "every manifest command's script exists"

out="$(HERDR_PLUGIN_ROOT="$root" HERDR_PLUGIN_CONFIG_DIR="$tmp/cfg" bash "$root/lib/link-bin")"
check "$(readlink "$tmp/cfg/bin")" "$root/bin" "link-bin points config bin at the plugin's bin"
check "$("$tmp/cfg/bin/agent-limits" bogus 2>&1 | head -1)" "usage: agent-limits [codex|agy [--3p]|claude|all|view|popup]" "scripts run through the symlink"
HERDR_PLUGIN_ROOT="$tmp/other" HERDR_PLUGIN_CONFIG_DIR="$tmp/cfg" bash "$root/lib/link-bin" >/dev/null
check "$(readlink "$tmp/cfg/bin")" "$tmp/other/bin" "link-bin repoints after an update"
check "$(env -u HERDR_PLUGIN_CONFIG_DIR bash "$root/lib/link-bin" 2>/dev/null; echo $?)" "1" "link-bin needs the config dir"

exit "$fail"
