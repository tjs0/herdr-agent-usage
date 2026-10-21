# herdr-agent-usage

A [Herdr](https://herdr.dev) plugin that shows how much of each coding agent's
rate limits you have used, and how full each pane's context is.

- A popup with every agent's account-wide 5h and 7d usage: Claude Code, Codex
  and Antigravity (`agy`).
- The same limits in the tab bar for the focused pane's agent.
- A `ctx N%` token per pane on Herdr's agent sidebar, for Claude, Codex and
  agy.

```
 Agent Usage
  claude   5h 13% 2h0m  7d 52% 3d
  codex    5h 66% 2h0m  7d 12% 3d
  agy      5h  8% 2h0m  7d  2% 3d
  agy 3p   5h  0% 2h0m  7d  0% 3d

  any key closes
```

Tab bar, focused pane running Claude or Codex: `5h 13% 2h0m  7d 52% 3d`. On
an agy pane both model groups share one line, the third-party one tagged:
`5h 8% 2h0m  7d 2% 3d │ [3p] 5h 0% 2h0m  7d 0% 3d`. The sidebar row shows
`ctx 42%` beside the agent name.

## Requirements

- Herdr 0.9.5 or newer.
- Linux. The scripts use GNU `tac`, `find -printf`, `stat -c`, `flock` and
  `date +%s%N`, so the manifest says `platforms = ["linux"]`.
- `bash`, `jq`, `awk`. `agy` on `PATH` (or `AGY_BIN`) for agy limits.

## Install

```sh
herdr plugin install tjs0/herdr-agent-usage
herdr plugin action invoke agent-usage.link
```

The `link` action creates `~/.config/herdr/plugins/config/agent-usage/bin`
(print the directory with `herdr plugin config-dir agent-usage`), a symlink to
the installed scripts. It also runs whenever the Herdr server starts.

## Wire it up

### Script paths

An install lives in a directory named with a commit hash, so `plugin_root`
(`herdr plugin list --json`) changes on every `herdr plugin update`. Configs
below use the stable symlink instead, written `$BIN`:

```
$BIN = $HOME/.config/herdr/plugins/config/agent-usage/bin
```

After `herdr plugin update`, the old install stays on disk until the server
restarts, and the startup hook then repoints the symlink; run
`herdr plugin action invoke agent-usage.link` to repoint it right away. Shell
configs may need the literal path where `$HOME` is not expanded.

### Popup keybinding

In `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "agent-usage.popup"
description = "agent usage"
```

The action opens the `usage` pane as a popup sized to the table. The popup is
a snapshot: Herdr cannot resize an open popup, so a redrawn table that grew
would overflow it. Reopen it for fresh numbers. Any key closes it.

### Tab bar

```toml
[ui]
tab_bar_right = [
  { type = "command", command = "$HOME/.config/herdr/plugins/config/agent-usage/bin/tab-right", interval_seconds = 1, timeout_seconds = 2 },
]
```

Herdr runs the command with `/bin/sh -lc`. Claude panes show the account's
5h and 7d usage, Codex panes the Codex limits, agy panes both agy groups; other
panes show nothing.

### Sidebar ctx

Show the `$ctx` token on agent rows:

```toml
[ui.sidebar.agents.rows_by_agent]
claude = [["state_icon", "workspace", "tab"], ["agent", "$ctx"]]
codex = [["state_icon", "workspace", "tab"], ["agent", "$ctx"]]
agy = [["state_icon", "workspace", "tab"], ["agent", "$ctx"]]
```

Copy your own `rows` and append `"$ctx"` to the agent row. Run
`herdr config check` afterward.

### Claude Code

In `~/.claude/settings.json`. `claude-statusline` prints Claude's own status
line (`ctx 42%  5h 18%  7d 61%`), merges the session's rate limits into the
account file, and inside Herdr reports the pane's `ctx`. `claude-session-end`
removes the pane's metrics file.

```json
{
  "statusLine": {
    "type": "command",
    "command": "$HOME/.config/herdr/plugins/config/agent-usage/bin/claude-statusline"
  },
  "hooks": {
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$HOME/.config/herdr/plugins/config/agent-usage/bin/claude-session-end" } ] }
    ]
  }
}
```

A new or cleared session has no percentage until its first reply and shows
`ctx ?%`.

### Codex

In `~/.codex/hooks.json`, under `"hooks"` (add a group beside any existing
entry for the same event):

```json
"SessionStart": [ { "hooks": [ { "type": "command", "command": "$HOME/.config/herdr/plugins/config/agent-usage/bin/codex-ctx-hook", "timeout": 10 } ] } ],
"Stop":         [ { "hooks": [ { "type": "command", "command": "$HOME/.config/herdr/plugins/config/agent-usage/bin/codex-ctx-hook", "timeout": 10 } ] } ],
"PostToolUse":  [ { "hooks": [ { "type": "command", "command": "$HOME/.config/herdr/plugins/config/agent-usage/bin/codex-ctx-hook", "timeout": 10 } ] } ]
```

Then trust the hooks in the Codex TUI with `/hooks`.

Codex TUIs share one background app-server daemon, which runs every session's
hooks with the environment of the pane that started it. Without a fix, all
hooks report to that one pane. Start Codex with `--no-daemon` inside Herdr so
each TUI runs its own server and hooks, for example:

```sh
codex() { if [ "$HERDR_ENV" = 1 ]; then command codex --no-daemon "$@"; else command codex "$@"; fi; }
```

The ctx percentage is Codex's own "context left" complement, with its fixed
12000-token baseline subtracted. Codex fires `SessionStart` only at a session's
first prompt, and nothing fires on `/clear`, so a cleared session keeps the old
value until its next prompt.

### Antigravity (agy)

In `~/.gemini/antigravity-cli/settings.json`. `agy-statusline` prints
`ctx N%` as agy's custom status line and, inside Herdr, reports the pane's
`ctx`. `stack_with_default` keeps agy's own status line above it.

```json
{
  "statusLine": {
    "type": "command",
    "command": "$HOME/.config/herdr/plugins/config/agent-usage/bin/agy-statusline",
    "stack_with_default": true
  }
}
```

The percentage is agy's own `context_window.used_percentage` from the status
line payload. A session still loading reports a zero window and shows `ctx ?%`;
a loaded session with no turns, or one just cleared, shows `ctx 0%`.

## Freshness

- Claude: from the account file `~/.cache/agent-limits/claude`, which every
  session's status line merges into. As fresh as the last Claude reply in any
  session. Per window, a reset more than an hour later is a newer window and
  wins; otherwise the higher usage wins. Nothing deletes the file.
- Codex: Codex writes `rate_limits` into each session's rollout under
  `~/.codex/sessions` on every turn, so the numbers are as fresh as the last
  Codex turn.
- agy: `agy -p /usage` answers without an agent turn or quota spend. The reply
  is cached in `~/.cache/agent-limits/agy.json` and refreshed in the background
  once it is a minute old (`AGY_TTL` seconds), so the tab bar never waits on it.
- A window whose reset time has passed shows `0%`.

Per-pane Claude metrics live in `~/.cache/claude-herdr/<pane-id>`. Both cache
roots follow `XDG_CACHE_HOME`.

## Commands

```
agent-limits [all|claude|codex|agy [--3p]|view|popup]
```

`agy` is the Gemini model group and `agy --3p` the third-party Claude and GPT
group. Any other model group agy reports gets its own popup row, labeled by
the words that set its name apart (`Gemini 4 Argon` is `agy argon`), and stays
out of the tab bar. Once a group hits its weekly limit, agy marks its 5h window disabled
and that window is left blank: `agy 3p  7d 100% 6d`.

## Tests

```sh
tests/run.sh
```
