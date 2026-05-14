#!/usr/bin/env sh
###############################################################################
# _lib.sh
#
# Shared helpers for AI-assistant notification hooks. Reusable across tools
# whose hook framework matches the "command + JSON on stdin" pattern (Claude
# Code, OpenAI Codex). Tool name is passed in as the first arg of each hook
# script (claude | codex) so this lib can adapt env var prefixes, settings
# directory walks, and notification titles.
#
# Loaded via POSIX dot-source from notification.sh and stop.sh:
#   . ~/.notification-hooks/_lib.sh
#
# This file MUST be POSIX-compliant (no bashisms). Hooks may be invoked under
# any /bin/sh implementation. Stick to `[`, `case`, `printf`, and avoid
# `[[ ... ]]`, `=~`, arrays, and `local`.
#
# Public functions (used by hooks):
#   find_parent_bundle               Find the bundle ID of the GUI app that
#                                    launched the calling tool (process tree
#                                    walk).
#   find_parent_bundle_cached        Same, cached to disk per session_id.
#   bundle_to_appname                Map a bundle ID to a brand-correct
#                                    display name.
#   build_subtitle                   Join project, branch, and app into a
#                                    separator string.
#   git_branch                       Current branch for a given cwd, or
#                                    empty when not in a repo.
#   find_project_settings_dir        Walk up from cwd to find the nearest
#                                    `.claude/` or `.codex/` directory.
#   get_setting                      Resolve a setting value across all
#                                    relevant settings.json scopes plus the
#                                    shell env. Tool-aware.
#   should_notify                    Return 0 (fire) or 1 (skip) based on
#                                    the appropriate per-tool toggle env
#                                    vars.
#   tool_title                       Branded title prefix for the given
#                                    tool: "Claude is waiting" vs.
#                                    "Codex is waiting" etc.
#   resolve_tool                     Normalise the tool arg to "claude" or
#                                    "codex", defaulting to "claude".
#
# Public variables:
#   NOTIFIER_BIN                     Absolute path to the custom-branded
#                                    terminal-notifier binary.
#
# Tool arg convention:
#   Each hook script accepts the tool name as its first positional arg.
#   Settings examples:
#     Claude:  "command": "sh ~/.notification-hooks/stop.sh claude"
#     Codex:   "command": "sh ~/.notification-hooks/stop.sh codex"
#   The lib functions take an explicit `tool` parameter where it matters;
#   callers pass through the resolved tool name.
###############################################################################

# -----------------------------------------------------------------------------
# Hooks directory
# -----------------------------------------------------------------------------
# Resolved by each entry-point script before this file is sourced. Falls
# back to ~/.notification-hooks/ when the caller hasn't set it, so this lib
# can still be dot-sourced directly for ad-hoc debugging.
#
# Entry-point scripts compute HOOKS_DIR with:
#   HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
#
# This makes the whole directory relocatable: clone or move it anywhere,
# update the paths in ~/.claude/settings.json and ~/.codex/hooks.json to
# match, and nothing else needs to change.
: "${HOOKS_DIR:=$HOME/.notification-hooks}"


# -----------------------------------------------------------------------------
# Notifier binary paths
# -----------------------------------------------------------------------------
# Each tool has its own custom-branded copy of terminal-notifier so macOS
# shows the right logo and per-tool notification permission entry:
#
#   claude-notifier.app  →  local.claude-notifier  →  Claude burst logo
#   codex-notifier.app   →  local.codex-notifier   →  Codex terminal logo
#
# `NOTIFIER_BIN` is kept as a backward-compatible default that points at the
# Claude bundle. New code should call `notifier_bin <tool>` instead so it
# always resolves to the right binary.
NOTIFIER_BIN="$HOOKS_DIR/claude-notifier.app/Contents/MacOS/terminal-notifier"

# Return the absolute path to the right terminal-notifier binary for the
# given tool. Falls back to the Claude bundle for unknown tools so old
# configs keep working.
notifier_bin() {
  case "$1" in
    codex)   printf '%s' "$HOOKS_DIR/codex-notifier.app/Contents/MacOS/terminal-notifier" ;;
    *)       printf '%s' "$HOOKS_DIR/claude-notifier.app/Contents/MacOS/terminal-notifier" ;;
  esac
}


# -----------------------------------------------------------------------------
# resolve_tool
# -----------------------------------------------------------------------------
# Normalise the tool name passed as the first script arg. Falls back to
# "claude" when nothing was passed, preserving backward compatibility with
# any old config that calls these scripts without a tool name.
resolve_tool() {
  case "$1" in
    codex|CODEX|Codex)    printf 'codex' ;;
    *)                    printf 'claude' ;;
  esac
}


# -----------------------------------------------------------------------------
# tool_title
# -----------------------------------------------------------------------------
# Return the brand-correct title for a notification, prefixed with an emoji
# that matches the current state for at-a-glance scanning in Notification
# Center.
#
# State to emoji map:
#   "is waiting"  → ⏳   (input or permission required)
#   "finished"    → ✅   (turn complete)
#   anything else → (no emoji)
#
# Tools have different brand styles ("Claude Code" feels too long; "Claude"
# reads better in a notification banner).
#
# Args: $1 = tool name (claude | codex)
#       $2 = state suffix ("is waiting" | "finished")
tool_title() {
  _tool="$1"
  _state="$2"
  _emoji=""
  case "$_state" in
    *waiting*)   _emoji='⏳ ' ;;
    *finished*)  _emoji='✅ ' ;;
  esac
  case "$_tool" in
    codex)   printf '%sCodex %s' "$_emoji" "$_state" ;;
    *)       printf '%sClaude %s' "$_emoji" "$_state" ;;
  esac
}


# -----------------------------------------------------------------------------
# find_parent_bundle
# -----------------------------------------------------------------------------
# Walks the parent process tree starting from this script's PID. For each
# ancestor, asks macOS LaunchServices what bundle ID owns that PID. Returns
# the first non-empty bundle ID, which is the GUI app that launched the
# calling tool (and therefore where notification clicks should open).
#
# Why walk the tree?
#   $TERM_PROGRAM reports `vscode` for VS Code, Cursor, and Windsurf alike,
#   but each has a distinct bundle ID. Process-tree introspection asks the
#   OS the authoritative question instead of trusting an env var.
#
# Output: bundle ID on stdout (e.g. "com.microsoft.VSCode"), or empty if
#         no GUI ancestor was found (e.g. running headless under launchd).
find_parent_bundle() {
  _pid=$$
  while [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" != "1" ]; do
    _bundle=$(lsappinfo info -only bundleid "$_pid" 2>/dev/null | awk -F'"' '{print $4}')
    if [ -n "$_bundle" ] && [ "$_bundle" != "CFBundleIdentifier" ]; then
      printf '%s' "$_bundle"
      return
    fi
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done
}


# -----------------------------------------------------------------------------
# find_parent_bundle_cached
# -----------------------------------------------------------------------------
# Same result as find_parent_bundle, but cached to disk per session_id. The
# uncached walk costs ~60ms; the cached lookup is a single cat.
#
# The cache is safe because the parent app cannot change during one session.
# State files live under ~/.notification-hooks-state/<session_id>.bundle.
#
# Args: $1 = session_id (falls back to uncached walk if empty)
find_parent_bundle_cached() {
  _sid="$1"
  [ -z "$_sid" ] && { find_parent_bundle; return; }

  _cache_dir="$HOME/.notification-hooks-state"
  _cache_file="$_cache_dir/$_sid.bundle"

  if [ -s "$_cache_file" ]; then
    cat "$_cache_file"
    return
  fi

  mkdir -p "$_cache_dir" 2>/dev/null
  _bundle=$(find_parent_bundle)
  if [ -n "$_bundle" ]; then
    printf '%s' "$_bundle" > "$_cache_file"
  fi
  printf '%s' "$_bundle"
}


# -----------------------------------------------------------------------------
# find_parent_tty
# -----------------------------------------------------------------------------
# Walks the parent process tree looking for the first process with a real
# controlling TTY. The hook itself usually has no TTY (it's a background
# process spawned by Claude/Codex), so we walk up until we find the user's
# interactive shell.
#
# Returns: full TTY path like "/dev/ttys003", or empty if none found.
#
# Useful for: locating the exact iTerm2 / Apple Terminal tab a hook fired
# from, so a notification click can focus that specific tab.
find_parent_tty() {
  _pid=$$
  while [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" != "1" ]; do
    _tty=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
    case "$_tty" in
      ttys*|ttyp*|tty*)
        printf '/dev/%s' "$_tty"
        return
        ;;
    esac
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done
}


# -----------------------------------------------------------------------------
# find_parent_tty_cached
# -----------------------------------------------------------------------------
# Same result as find_parent_tty, but cached per session_id. The TTY of the
# shell that owns Claude/Codex doesn't change during a session.
find_parent_tty_cached() {
  _sid="$1"
  [ -z "$_sid" ] && { find_parent_tty; return; }

  _cache_dir="$HOME/.notification-hooks-state"
  _cache_file="$_cache_dir/$_sid.tty"

  if [ -s "$_cache_file" ]; then
    cat "$_cache_file"
    return
  fi

  mkdir -p "$_cache_dir" 2>/dev/null
  _tty=$(find_parent_tty)
  if [ -n "$_tty" ]; then
    printf '%s' "$_tty" > "$_cache_file"
  fi
  printf '%s' "$_tty"
}


# -----------------------------------------------------------------------------
# bundle_to_appname
# -----------------------------------------------------------------------------
# Map a bundle ID to a brand-correct display name. `lsappinfo info -only name`
# returns the binary name (e.g. "Code") rather than the brand name
# ("VS Code"), so we maintain an explicit case mapping. Unknown bundles fall
# back to the last reverse-DNS segment.
bundle_to_appname() {
  case "$1" in
    com.microsoft.VSCode)            printf 'VS Code' ;;
    com.microsoft.VSCodeInsiders)    printf 'VS Code Insiders' ;;
    com.todesktop.230313mzl4w4u92)   printf 'Cursor' ;;
    com.exafunction.windsurf)        printf 'Windsurf' ;;
    com.google.antigravity)          printf 'Antigravity' ;;
    com.googlecode.iterm2)           printf 'iTerm2' ;;
    com.apple.Terminal)              printf 'Terminal' ;;
    dev.warp.Warp-Stable)            printf 'Warp' ;;
    com.mitchellh.ghostty)           printf 'Ghostty' ;;
    com.github.wez.wezterm)          printf 'WezTerm' ;;
    net.kovidgoyal.kitty)            printf 'kitty' ;;
    co.zeit.hyper)                   printf 'Hyper' ;;
    *)                               printf '%s' "$1" | awk -F. '{print $NF}' ;;
  esac
}


# -----------------------------------------------------------------------------
# build_subtitle
# -----------------------------------------------------------------------------
# Joins up to three pieces with " · ", skipping empties. Not currently used
# by the hooks (long content lives in the message body to avoid macOS's
# subtitle truncation) but kept for reuse.
build_subtitle() {
  _project="$1"
  _branch="$2"
  _app="$3"
  _out="$_project"
  [ -n "$_branch" ] && _out="$_out · $_branch"
  [ -n "$_app" ] && _out="$_out · $_app"
  printf '%s' "$_out"
}


# -----------------------------------------------------------------------------
# git_branch
# -----------------------------------------------------------------------------
# Returns the current branch name for a given working directory. Silent
# (no output, no error) when the dir is not inside a git work tree.
git_branch() {
  _cwd="$1"
  if git -C "$_cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$_cwd" branch --show-current 2>/dev/null
  fi
}


# -----------------------------------------------------------------------------
# find_project_settings_dir
# -----------------------------------------------------------------------------
# Walks upward from a starting directory looking for either a `.claude/` or
# `.codex/` config directory. Both Claude Code and Codex use the same
# parent-walk heuristic to find their project scope.
#
# Returns the absolute path on stdout (e.g. "/path/to/repo/.claude" or
# "/path/to/repo/.codex"), or empty if neither was found before reaching /.
#
# Why support both?
#   This file is dot-sourced from hooks that may be wired into either tool.
#   When called from a Codex hook in a project that has only `.codex/`,
#   we don't want to ignore that scope's `env` block just because there's
#   no `.claude/` next to it.
#
# Args: $1 = starting dir (defaults to $PWD)
#       $2 = preferred tool name ("claude" | "codex"). When both
#            directories exist at the same level, the tool's own dir wins.
find_project_settings_dir() {
  _d="${1:-$PWD}"
  _preferred="${2:-claude}"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    if [ "$_preferred" = "codex" ] && [ -d "$_d/.codex" ]; then
      printf '%s' "$_d/.codex"
      return
    fi
    if [ "$_preferred" = "claude" ] && [ -d "$_d/.claude" ]; then
      printf '%s' "$_d/.claude"
      return
    fi
    if [ -d "$_d/.claude" ]; then
      printf '%s' "$_d/.claude"
      return
    fi
    if [ -d "$_d/.codex" ]; then
      printf '%s' "$_d/.codex"
      return
    fi
    _d=$(dirname "$_d")
  done
}


# -----------------------------------------------------------------------------
# get_setting
# -----------------------------------------------------------------------------
# Resolve a setting value by name across the standard settings precedence
# chain for the calling tool. Each scope's config file is checked via jq
# (for JSON) or awk (for TOML); the first non-empty match wins.
#
# Precedence (highest first):
#   1. Shell environment variable
#   2. <project>/.<tool>/<config>   project local + project committed
#   3. ~/.<tool>/<config>           global local + global user-wide
#
# Claude uses settings.json and settings.local.json. Codex uses hooks.json
# and config.toml. The candidate file list flips based on the tool arg.
#
# Args:
#   $1 = variable name (e.g. "CLAUDE_NOTIFICATIONS")
#   $2 = cwd from hook payload (used to locate the project's settings dir)
#   $3 = tool name ("claude" | "codex"), defaults to "claude"
get_setting() {
  _var="$1"
  _cwd="${2:-$PWD}"
  _tool="${3:-claude}"

  eval "_shell_val=\${$_var:-}"
  if [ -n "$_shell_val" ]; then
    printf '%s' "$_shell_val"
    return
  fi

  _proj_settings=$(find_project_settings_dir "$_cwd" "$_tool")

  if [ "$_tool" = "codex" ]; then
    _files="$_proj_settings/hooks.json $_proj_settings/config.toml $HOME/.codex/hooks.json $HOME/.codex/config.toml"
  else
    _files="$_proj_settings/settings.local.json $_proj_settings/settings.json $HOME/.claude/settings.local.json $HOME/.claude/settings.json"
  fi

  for _f in $_files; do
    [ -z "$_f" ] && continue
    [ -f "$_f" ] || continue
    case "$_f" in
      *.json)
        _v=$(jq -r --arg n "$_var" '.env[$n] // empty' "$_f" 2>/dev/null)
        ;;
      *.toml)
        # Minimal TOML extraction for the form: env.<KEY> = "value"
        # Codex's TOML doesn't have a documented env block, so this is a
        # best-effort fallback for users who keep the toggle in config.toml.
        _v=$(awk -v key="$_var" '
          /^[[:space:]]*env\./ {
            if (match($0, /env\.[^[:space:]=]+/)) {
              k=substr($0, RSTART+4, RLENGTH-4)
              gsub(/"/, "", k)
              if (k == key) {
                if (match($0, /=[[:space:]]*"[^"]*"/)) {
                  v=substr($0, RSTART, RLENGTH)
                  gsub(/^=[[:space:]]*"|"$/, "", v)
                  print v
                  exit
                }
              }
            }
          }
        ' "$_f" 2>/dev/null)
        ;;
    esac
    if [ -n "$_v" ]; then
      printf '%s' "$_v"
      return
    fi
  done
}


# -----------------------------------------------------------------------------
# should_notify
# -----------------------------------------------------------------------------
# Check whether notifications are enabled for the calling hook event. Two
# layers of toggle:
#   <PREFIX>_NOTIFICATIONS          master kill switch for all hooks
#   <PREFIX>_NOTIFICATIONS_<EVENT>  per-event override (e.g. _STOP, _INPUT)
#
# <PREFIX> is "CLAUDE" or "CODEX" based on the calling tool, so each tool
# can be toggled independently. Disable values (case insensitive): off, 0,
# false, no.
#
# Args:
#   $1 = event suffix in uppercase (e.g. "STOP", "INPUT")
#   $2 = cwd from the hook payload
#   $3 = tool name ("claude" | "codex"), defaults to "claude"
#
# Return: 0 (enabled) or 1 (disabled).
should_notify() {
  _event="$1"
  _cwd="$2"
  _tool="${3:-claude}"
  _prefix="CLAUDE"
  [ "$_tool" = "codex" ] && _prefix="CODEX"

  case "$(get_setting "${_prefix}_NOTIFICATIONS" "$_cwd" "$_tool")" in
    off|OFF|0|false|FALSE|no|NO) return 1 ;;
  esac

  if [ -n "$_event" ]; then
    case "$(get_setting "${_prefix}_NOTIFICATIONS_$_event" "$_cwd" "$_tool")" in
      off|OFF|0|false|FALSE|no|NO) return 1 ;;
    esac
  fi

  return 0
}
