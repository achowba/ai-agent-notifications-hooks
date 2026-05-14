#!/usr/bin/env sh
###############################################################################
# stop.sh
#
# Cross-tool turn-end notification hook. Fires when an AI assistant
# finishes a turn. Both Claude Code and OpenAI Codex emit a `Stop` event
# with compatible payloads (cwd + session_id present in both).
#
# Usage from each tool's config:
#
#   Claude Code (~/.claude/settings.json):
#     "Stop": [{ "matcher": "",
#       "hooks": [{ "type": "command",
#                   "command": "sh ~/.notification-hooks/stop.sh claude" }] }]
#
#   Codex (~/.codex/hooks.json):
#     "Stop": [{
#       "hooks": [{ "type": "command",
#                   "command": "sh ~/.notification-hooks/stop.sh codex" }] }]
#
# Note: Codex's Stop hook expects JSON on stdout when it exits 0 (or empty
# output, which is treated as success). This script emits nothing, so it
# is silently accepted as a "do not continue" signal. If you ever want to
# auto-continue a Codex turn from here, emit:
#   {"decision":"block","reason":"..."}
#
# Stdin payload fields used:
#   .cwd               both tools
#   .session_id        both tools
#
# Notification layout:
#   Title    "<Tool> finished"            "Claude finished" or "Codex finished"
#   Subtitle "<app>"                      short, brand-correct app name
#   Body     line 1: "<project>"          repo / dir name
#            line 2: "<branch>"           git branch (omitted outside a repo)
#            line 3: "Task complete"      literal status string
###############################################################################

# Resolve this script's own directory so the hooks system can live anywhere
# on disk. See notification.sh for full rationale.
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS_DIR/_lib.sh"

tool=$(resolve_tool "$1")

# Pick the branded notifier binary for this tool. Each tool has its own
# .app bundle with the right icon and bundle ID.
NOTIFIER_BIN=$(notifier_bin "$tool")

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

should_notify STOP "$cwd" "$tool" || exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
project=$(basename "$cwd")
branch=$(git_branch "$cwd")
bundle=$(find_parent_bundle_cached "$session_id")
app=""
[ -n "$bundle" ] && app=$(bundle_to_appname "$bundle")

# Cache TTY and cwd so focus.sh can switch to the exact tab/window when
# the notification is clicked. Same lifetime as the bundle cache.
tty=$(find_parent_tty_cached "$session_id")
if [ -n "$session_id" ] && [ -n "$cwd" ]; then
  mkdir -p "$HOME/.notification-hooks-state" 2>/dev/null
  printf '%s' "$cwd" > "$HOME/.notification-hooks-state/$session_id.cwd"
fi

# Read the last user prompt for this session, written by user_prompt.sh on
# UserPromptSubmit. Falls back to "Task complete" if the hook wasn't wired
# up, this is a fresh session with no prompts yet, or the file is empty.
#
# Truncation rules at display time:
#   - Collapse all whitespace runs (including newlines) into single spaces
#     so multi-line prompts render on one body line.
#   - Trim leading/trailing whitespace.
#   - Cap at 100 chars and append an ellipsis when truncated.
prompt_summary=""
prompt_file="$HOME/.notification-hooks-state/$session_id.prompt"
if [ -s "$prompt_file" ]; then
  raw=$(tr -s '[:space:]' ' ' < "$prompt_file" | sed 's/^ *//; s/ *$//')
  if [ ${#raw} -gt 100 ]; then
    prompt_summary=$(printf '%s' "$raw" | cut -c1-97)...
  else
    prompt_summary="$raw"
  fi
fi

body="$project"
[ -n "$branch" ] && body=$(printf '%s\n%s' "$body" "$branch")
if [ -n "$prompt_summary" ]; then
  body=$(printf '%s\n%s' "$body" "$prompt_summary")
else
  body=$(printf '%s\nTask complete' "$body")
fi

title=$(tool_title "$tool" "finished")

# Click handling: see notification.sh for the rationale on `-execute` vs.
# `-activate`. focus.sh reads the cached state and uses app-specific
# AppleScript to focus the tab or window the hook fired from.
if [ -n "$session_id" ]; then
  ( "$NOTIFIER_BIN" \
      -title "$title" \
      -subtitle "$app" \
      -message "$body" \
      -sound Pop \
      -execute "sh $HOOKS_DIR/focus.sh $session_id" >/dev/null 2>&1 ) &
else
  ( "$NOTIFIER_BIN" \
      -title "$title" \
      -subtitle "$app" \
      -message "$body" \
      -sound Pop >/dev/null 2>&1 ) &
fi
