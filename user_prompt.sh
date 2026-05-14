#!/usr/bin/env sh
###############################################################################
# user_prompt.sh
#
# Captures the user's most recent prompt to a per-session state file. Read
# by stop.sh to include the task description in turn-end notifications.
#
# Usage from each tool's config:
#
#   Claude Code (~/.claude/settings.json):
#     "UserPromptSubmit": [{ "matcher": "",
#       "hooks": [{ "type": "command",
#                   "command": "sh ~/.notification-hooks/user_prompt.sh claude" }] }]
#
#   Codex (~/.codex/hooks.json):
#     "UserPromptSubmit": [{
#       "hooks": [{ "type": "command",
#                   "command": "sh ~/.notification-hooks/user_prompt.sh codex" }] }]
#
# Stdin payload fields used:
#   .session_id        both tools
#   .prompt            both tools (the text the user just submitted)
#
# Output: this script must print NOTHING to stdout. Both tools treat hook
# stdout as developer-context injection: any output here would silently
# leak into the model's context. All writes go to disk only.
#
# State file: ~/.notification-hooks-state/<session_id>.prompt
#   Overwritten on each turn, so the file always holds the most recent
#   prompt for that session. Read by stop.sh and notification.sh.
###############################################################################

. ~/.notification-hooks/_lib.sh

# resolve_tool is called for future-proofing; the prompt capture itself
# is identical across tools. Adding the arg keeps the calling convention
# consistent with notification.sh and stop.sh.
tool=$(resolve_tool "$1")

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
prompt=$(printf '%s' "$input" | jq -r '.prompt // empty')

# Silently exit if we can't identify the session or there's no prompt.
# A missing session_id breaks the read path; an empty prompt provides
# nothing useful to display.
[ -z "$session_id" ] && exit 0
[ -z "$prompt" ] && exit 0

state_dir="$HOME/.notification-hooks-state"
mkdir -p "$state_dir" 2>/dev/null

# Write the raw prompt. stop.sh handles truncation and newline collapsing
# at display time so this file stays a faithful record of what the user
# actually typed.
printf '%s' "$prompt" > "$state_dir/$session_id.prompt"

exit 0
