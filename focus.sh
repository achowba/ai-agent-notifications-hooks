#!/usr/bin/env sh
###############################################################################
# focus.sh
#
# Click handler for notifications. Reads cached state for the given session
# and runs the right AppleScript to focus the specific terminal tab or
# window the hook fired from.
#
# Invoked by terminal-notifier via:
#   -execute "sh ~/.notification-hooks/focus.sh <session_id>"
#
# Per-app behavior:
#   iTerm2          Focus the tab whose session TTY matches the cached TTY.
#   Apple Terminal  Same as iTerm2.
#   VS Code family  Focus the window whose title contains the project name.
#                   (Tab focus is not possible from outside VS Code without
#                   an installed extension; this is the best macOS allows.)
#   Other apps      Fall back to plain `tell application id "..." to activate`.
#
# Requires: macOS Accessibility permission for the VS Code path (System
# Events is used to walk windows). The first attempt may fail silently
# until the permission is granted in System Settings, Privacy & Security,
# Accessibility. Once granted, subsequent clicks work.
#
# State files used (all under ~/.notification-hooks-state/):
#   <session_id>.bundle   bundle ID of the parent GUI app
#   <session_id>.tty      TTY of the parent shell (iTerm/Terminal focus)
#   <session_id>.cwd      working dir (used for VS Code window title match)
###############################################################################

sid="$1"
state_dir="$HOME/.notification-hooks-state"

# Soft-fail if nothing to do.
[ -z "$sid" ] && exit 0

bundle=""
tty=""
cwd=""
[ -f "$state_dir/$sid.bundle" ] && bundle=$(cat "$state_dir/$sid.bundle")
[ -f "$state_dir/$sid.tty" ] && tty=$(cat "$state_dir/$sid.tty")
[ -f "$state_dir/$sid.cwd" ] && cwd=$(cat "$state_dir/$sid.cwd")
project=""
[ -n "$cwd" ] && project=$(basename "$cwd")

# Always at minimum activate the bundle, so clicking does *something*
# useful even when the tab/window-specific AppleScript fails.
if [ -n "$bundle" ]; then
  osascript -e "tell application id \"$bundle\" to activate" 2>/dev/null || true
fi

case "$bundle" in
  com.googlecode.iterm2)
    # iTerm2's API uses sessions (tab content), tabs (containers of sessions),
    # and windows. Each session has a `tty` property that uniquely identifies
    # the underlying pty, so matching is trivial. We `select` both the window
    # and the tab so the right combination becomes frontmost.
    [ -z "$tty" ] && exit 0
    osascript <<APPLESCRIPT 2>/dev/null
tell application "iTerm"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if tty of s is "$tty" then
          tell w to select
          tell t to select
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
APPLESCRIPT
    ;;

  com.apple.Terminal)
    # Apple Terminal exposes `tty` on tab objects directly. Setting
    # `selected tab` plus bringing the window to index 1 surfaces the tab.
    [ -z "$tty" ] && exit 0
    osascript <<APPLESCRIPT 2>/dev/null
tell application "Terminal"
  activate
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$tty" then
        set selected tab of w to t
        set index of w to 1
        return
      end if
    end repeat
  end repeat
end tell
APPLESCRIPT
    ;;

  com.microsoft.VSCode|com.microsoft.VSCodeInsiders|com.todesktop.230313mzl4w4u92|com.exafunction.windsurf|com.google.antigravity)
    # VS Code family: VS Code, Cursor, Windsurf, Antigravity (Google's
    # fork). All share the same architecture (Electron with multiple
    # browser windows per project) so the same window-title-matching
    # focus strategy works for each.
    #
    # System Events drives macOS Accessibility, which is the only way to
    # enumerate these apps' windows from outside. Each fork uses a
    # different process name, so we map bundle ID to process name explicitly.
    #
    # Requires Accessibility permission, granted once via System Settings,
    # Privacy & Security, Accessibility. The first click may fail silently
    # until you allow terminal-notifier (or osascript) in that pane.
    [ -z "$project" ] && exit 0
    case "$bundle" in
      com.microsoft.VSCode)           proc_name="Code" ;;
      com.microsoft.VSCodeInsiders)   proc_name="Code - Insiders" ;;
      com.todesktop.230313mzl4w4u92)  proc_name="Cursor" ;;
      com.exafunction.windsurf)       proc_name="Windsurf" ;;
      com.google.antigravity)         proc_name="Antigravity" ;;
      *)                              proc_name="Code" ;;
    esac
    osascript <<APPLESCRIPT 2>/dev/null
tell application "System Events"
  tell process "$proc_name"
    set frontmost to true
    try
      repeat with w in windows
        if title of w contains "$project" then
          perform action "AXRaise" of w
          return
        end if
      end repeat
    end try
  end tell
end tell
APPLESCRIPT
    ;;

  *)
    # Already activated above. Nothing more to do for unsupported apps.
    ;;
esac
