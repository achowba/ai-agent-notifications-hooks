#!/usr/bin/env sh
###############################################################################
# notification.sh
#
# Cross-tool notification hook. Surfaces a macOS notification when the
# calling AI assistant is waiting for user input or permission. Supports
# Claude Code, OpenAI Codex, and xAI Grok.
#
# Usage from each tool's config:
#
#   Claude Code (~/.claude/settings.json):
#     "Notification": [{ "matcher": "",
#       "hooks": [{ "type": "command",
#                   "command": "sh ~/.notification-hooks/notification.sh claude" }] }]
#
#   Codex (~/.codex/hooks.json):
#     "PermissionRequest": [{ "matcher": "",
#       "hooks": [{ "type": "command",
#                   "command": "sh ~/.notification-hooks/notification.sh codex" }] }]
#
# Why a different event per tool?
#   Claude fires `Notification` for permission prompts and idle input waits.
#   Codex fires `PermissionRequest` only when escalating to a permission
#   prompt; there is no separate idle-input event in Codex.
#
# Stdin payload fields (try in order):
#   .message                       Claude's prompt text
#   .tool_input.description        Codex's permission reason (snake_case)
#   .toolInput.description         Grok's permission reason (camelCase)
#   .prompt                        Codex UserPromptSubmit fallback
#   .cwd                           All tools
#   .session_id // .sessionId      Claude/Codex use snake_case; Grok camelCase
#
# Notification layout:
#   Title    "⏳ <Tool> is waiting"          "⏳ Claude is waiting" or "⏳ Codex is waiting"
#   Subtitle "<app>"                         short, brand-correct app name
#   Body     line 1: "<project>"             repo / dir name
#            line 2: "<branch>"              git branch (omitted outside a repo)
#            line 3: "<message>"             the actual prompt or description
###############################################################################

# Resolve this script's own directory so the hooks system can live anywhere
# on disk. settings.json / hooks.json point at a specific path; everything
# else (the sourced lib, the .app bundles, the click handler) is found
# relative to wherever this script actually lives.
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS_DIR/_lib.sh"

# Resolve the tool name. First arg should be "claude", "codex", or "grok";
# defaults to "claude" for backward compatibility with configs that haven't
# been updated yet.
tool=$(resolve_tool "$1")

# Pick the branded notifier binary for this tool. Each tool has its own
# .app bundle with the right icon and bundle ID.
NOTIFIER_BIN=$(notifier_bin "$tool")

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# Toggle gate. Honours CLAUDE_NOTIFICATIONS{,_INPUT} when called from Claude
# and CODEX_NOTIFICATIONS{,_INPUT} when called from Codex.
should_notify INPUT "$cwd" "$tool" || exit 0

# Pull the message text. Try Claude's `.message` first (the historical
# field name), then Codex's `.tool_input.description` (used by
# PermissionRequest), then Grok's `.toolInput.description` (camelCase
# equivalent), then `.prompt` (used by UserPromptSubmit), then a generic
# fallback string. Tools that don't populate any of these still get a
# sensible notification with just the project/branch context.
msg=$(printf '%s' "$input" | jq -r '
  .message
  // .tool_input.description
  // .toolInput.description
  // .prompt
  // "needs your attention"
')

# Grok emits camelCase (`sessionId`) per the runtime contract; Claude and
# Codex use snake_case. Read both so the script is tool-agnostic.
session_id=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty')
project=$(basename "$cwd")
branch=$(git_branch "$cwd")

# Calling-app detection. Cached per session_id so the tree walk happens
# once per session.
bundle=$(find_parent_bundle_cached "$session_id")
app=""
[ -n "$bundle" ] && app=$(bundle_to_appname "$bundle")

# Cache the TTY and cwd so focus.sh (the click handler) can switch to the
# exact tab/window where the hook fired. Both are stable per session.
tty=$(find_parent_tty_cached "$session_id")
if [ -n "$session_id" ] && [ -n "$cwd" ]; then
  mkdir -p "$HOME/.notification-hooks-state" 2>/dev/null
  printf '%s' "$cwd" > "$HOME/.notification-hooks-state/$session_id.cwd"
fi

# Multi-line body. Project on line 1, branch on line 2 (if in a repo),
# message on the last line. `printf '%s\n%s'` emits real LF characters,
# which terminal-notifier and macOS Notification Center render as
# expandable line breaks.
body="$project"
[ -n "$branch" ] && body=$(printf '%s\n%s' "$body" "$branch")
body=$(printf '%s\n%s' "$body" "$msg")

# Branded title for the calling tool.
title=$(tool_title "$tool" "is waiting")

# Background the notifier so the hook returns immediately. See README's
# "Background execution" section for why.
#
# Click handling: `-execute` runs focus.sh with the session ID, which
# reads the cached bundle/tty/cwd state and runs app-specific AppleScript
# to focus the exact tab (iTerm2, Apple Terminal) or window (VS Code
# family). For unsupported apps it falls back to plain app activation.
#
# We prefer `-execute` over `-activate` because the former gives us full
# control over the focus behaviour. Both flags are mutually exclusive in
# terminal-notifier; you pick one per call.
if [ -n "$session_id" ]; then
  ( "$NOTIFIER_BIN" \
      -title "$title" \
      -subtitle "$app" \
      -message "$body" \
      -sound Glass \
      -execute "sh $HOOKS_DIR/focus.sh $session_id" >/dev/null 2>&1 ) &
else
  ( "$NOTIFIER_BIN" \
      -title "$title" \
      -subtitle "$app" \
      -message "$body" \
      -sound Glass >/dev/null 2>&1 ) &
fi
