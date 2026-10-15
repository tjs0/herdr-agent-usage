# TODO

Open items, most important first.

1. agy context usage ("ctx N%"): needs a readable source. Its conversations
   are protobuf blobs in SQLite (`~/.gemini/antigravity-cli/conversations/`).
   Waiting on
   [antigravity-cli#1236](https://github.com/google-antigravity/antigravity-cli/issues/1236).
2. Account limits in the sidebar instead of only the popup and tab bar:
   waiting on a plugin-owned sidebar section,
   [herdr discussion #1609](https://github.com/herdrdev/herdr/discussions/1609).
3. macOS support: replace `tac`, `find -printf`, `stat -c`, `flock` and
   `date +%s%N`, then add `macos` to `platforms`.
