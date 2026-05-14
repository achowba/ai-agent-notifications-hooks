#!/usr/bin/env sh
###############################################################################
# pre_tool_use.sh
#
# Fires a notification when Claude is about to use a tool that typically
# requires user permission (Write, Edit, Bash). Gated by system idle time
# so it stays silent when you're actively at the keyboard and only chirps
# when you've tabbed away.
#
# Wired into ~/.claude/settings.json:
#   "PreToolUse": [{
#     "matcher": "Write|Edit|Bash",
#     "hooks": [{"type": "command",
#                "command": "sh ~/.notification-hooks/pre_tool_use.sh claude"}]
#   }]
#
# Why this exists:
#   Claude Code's `Notification` event does NOT fire when Claude pauses on
#   a tool permission prompt (confirmed on 2.1.141). It only fires for
#   idle waits between turns. To get a "Claude needs your attention"
#   notification at permission prompts, we hook PreToolUse instead and
#   gate it by idle time so it doesn't spam during active work.
#
# Stdin payload fields used:
#   .tool_name        "Write", "Edit", or "Bash"
#   .tool_input       tool-specific input (file_path for Edit/Write,
#                                          command for Bash)
#   .cwd              project root
#   .session_id       session UUID
###############################################################################

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS_DIR/_lib.sh"

tool=$(resolve_tool "$1")
NOTIFIER_BIN=$(notifier_bin "$tool")

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')

# Reuse the INPUT toggle gate. Both Notification and PreToolUse serve the
# same UX purpose ("Claude needs your attention"), so a single toggle
# controls both.
should_notify INPUT "$cwd" "$tool" || exit 0

# Idle gate: only notify if no keyboard or mouse activity for >= 5 seconds.
# HIDIdleTime is reported in nanoseconds; divide by 1e9 to get seconds.
# When the user is actively in the terminal, this gate exits early so we
# don't spam every Edit / Write / Bash call.
idle=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
[ -z "$idle" ] && idle=0
if [ "$idle" -lt 5 ]; then
  exit 0
fi

# Pull tool info for the notification body.
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // "Tool"')
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')

# Tool-specific summary line shown in the notification body.
case "$tool_name" in
  Write)
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
    detail="Wants to create: $target"
    ;;
  Edit)
    target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')
    detail="Wants to edit: $target"
    ;;
  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
    # Truncate long commands so the body line stays readable.
    if [ "${#cmd}" -gt 80 ]; then
      cmd=$(printf '%s' "$cmd" | cut -c1-77)...
    fi
    detail="Wants to run: $cmd"
    ;;
  *)
    detail="Needs permission for $tool_name"
    ;;
esac

project=$(basename "$cwd")
branch=$(git_branch "$cwd")
bundle=$(find_parent_bundle_cached "$session_id")
app=""
[ -n "$bundle" ] && app=$(bundle_to_appname "$bundle")

# Cache cwd + tty so focus.sh can switch to the right window on click.
tty=$(find_parent_tty_cached "$session_id")
if [ -n "$session_id" ] && [ -n "$cwd" ]; then
  mkdir -p "$HOME/.notification-hooks-state" 2>/dev/null
  printf '%s' "$cwd" > "$HOME/.notification-hooks-state/$session_id.cwd"
fi

body="$project"
[ -n "$branch" ] && body=$(printf '%s\n%s' "$body" "$branch")
body=$(printf '%s\n%s' "$body" "$detail")

title=$(tool_title "$tool" "is waiting")

# Background the notifier so the hook returns immediately. Claude waits for
# hook completion before continuing; backgrounding keeps the wait under
# ~100 ms so the assistant stays responsive.
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
