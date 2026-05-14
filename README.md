# AI Assistant Notification Hooks (macOS)

A self-contained, tool-neutral setup that turns Claude Code and OpenAI Codex into quiet background companions. Get a desktop notification when either assistant needs your input or finishes a turn, click it to jump back into your terminal or IDE, and toggle the whole thing on or off per project and per tool.

## What you get

| Feature | Description |
|---|---|
| Desktop notification when waiting for input | "Claude is waiting" (Claude `Notification` event) or "Codex is waiting" (Codex `PermissionRequest` event). Glass sound. |
| Desktop notification when a turn ends | "Claude finished" or "Codex finished". Pop sound. |
| Click target is your terminal or IDE | Walks the process tree at runtime to identify VS Code, Cursor, Windsurf, Antigravity, iTerm2, Apple Terminal, etc. Clicking the notification focuses that app and, where the app's scripting API allows, the specific tab or window the hook fired from. |
| Project, branch, and message in the body | Multi-line message body so long branch names and prompt text wrap naturally. |
| Custom branded icon | A separate `.app` bundle with your logo baked in, distinct from any Homebrew `terminal-notifier` install. |
| Per-tool, per-event, per-scope toggles | `CLAUDE_NOTIFICATIONS_*` and `CODEX_NOTIFICATIONS_*` resolved across shell env, project config dirs, and global config dirs. |

## Architecture overview

```
        Claude Code                                  OpenAI Codex
            │                                              │
   ~/.claude/settings.json                       ~/.codex/hooks.json
            │                                              │
            └────────────────┬─────────────────────────────┘
                             │
                             ▼
                ~/.notification-hooks/notification.sh <tool>
                ~/.notification-hooks/stop.sh         <tool>
                             │
                             ▼
                ~/.notification-hooks/_lib.sh
                (shared helpers + NOTIFIER_BIN)
                             │
                             ▼
                ~/.notification-hooks/claude-notifier.app
                (custom terminal-notifier with branded icon)
                             │
                             ▼
                     macOS Notification API
```

Each tool's config file calls the same hook script and passes its tool name (`claude` or `codex`) as the first positional argument. The scripts use that to:
1. Pick the right title prefix (`Claude is waiting` vs `Codex is waiting`)
2. Pick the right env var prefix for toggles (`CLAUDE_NOTIFICATIONS_*` vs `CODEX_NOTIFICATIONS_*`)
3. Walk the right project settings dir (`.claude/` vs `.codex/`)

## File map

| Path | Role |
|---|---|
| `~/.claude/settings.json` | Wires Claude's `Notification` and `Stop` events into the hooks. |
| `~/.codex/hooks.json` (or `~/.codex/config.toml`) | Wires Codex's `PermissionRequest` and `Stop` events into the hooks. |
| `~/.notification-hooks/_lib.sh` | Shared POSIX shell helpers. Bundle detection, branch lookup, settings resolution, toggle gating, tool-name routing. |
| `~/.notification-hooks/notification.sh` | Handler for "waiting for input" events. Accepts `claude` or `codex` as the first arg. |
| `~/.notification-hooks/user_prompt.sh` | Handler for `UserPromptSubmit`. Captures the user's most recent prompt to a state file so `stop.sh` can show it in the turn-end notification. |
| `~/.notification-hooks/stop.sh` | Handler for turn-end events. Accepts `claude` or `codex` as the first arg. Reads the captured prompt from the state file and uses it as the body's last line; falls back to "Task complete" when no prompt was captured. |
| `~/.notification-hooks/focus.sh` | Click handler. Invoked by `terminal-notifier -execute` when the notification is clicked. Reads cached state for the session and runs the right AppleScript per app to focus the specific tab (iTerm2, Apple Terminal) or window (VS Code, Cursor, Windsurf, Antigravity). |
| `~/.notification-hooks/claude-notifier.app` | Branded `terminal-notifier` bundle used by Claude hooks. Bundle ID `local.claude-notifier`. |
| `~/.notification-hooks/codex-notifier.app` | Branded `terminal-notifier` bundle used by Codex hooks. Bundle ID `local.codex-notifier`. |
| `~/.notification-hooks/assets/claude-logo.png` | Source PNG for the Claude icon. |
| `~/.notification-hooks/assets/codex-logo.png` | Source PNG for the Codex icon. |
| `~/.notification-hooks/assets/claude.icns` | Generated icon set for the Claude bundle. |
| `~/.notification-hooks/assets/codex.icns` | Generated icon set for the Codex bundle. |
| `~/.notification-hooks/assets/claude.iconset/` | Per-resolution PNGs for the Claude bundle. |
| `~/.notification-hooks/assets/codex.iconset/` | Per-resolution PNGs for the Codex bundle. |
| `~/.notification-hooks-state/` | Tiny per-session state files. `<session_id>.bundle` caches the parent bundle ID; `<session_id>.prompt` holds the most recent user prompt for that session, used as the turn-end notification body. |

## Prerequisites

| Requirement | How to get it |
|---|---|
| macOS 12 or later | n/a |
| At least one of Claude Code or Codex installed | https://code.claude.com/docs and https://developers.openai.com/codex |
| Homebrew | https://brew.sh |
| `terminal-notifier` | `brew install terminal-notifier` |
| `jq` | `brew install jq` |
| Xcode command-line tools | `xcode-select --install` (needed for `iconutil`, `sips`, `codesign`) |

## Installation on a fresh machine

### 1. Drop the scripts into place

Copy these three files into `~/.notification-hooks/`. They are POSIX shell, so no execute bit is required: hooks are invoked as `sh <path>`.

```
~/.notification-hooks/_lib.sh
~/.notification-hooks/notification.sh
~/.notification-hooks/stop.sh
```

### 2. Install `terminal-notifier`

```sh
brew install terminal-notifier
```

The upstream binary lives at `/opt/homebrew/bin/terminal-notifier` (Apple Silicon) or `/usr/local/bin/terminal-notifier` (Intel). The hooks do not call this binary directly; it is the template for the custom branded bundle below.

### 3. Build the branded notifier bundles

One bundle per tool, so each tool gets the right icon and its own notification permission entry. The block below builds the Claude bundle; repeat with `codex` substituted for `claude` (and a different source PNG) to build the Codex bundle.

Drop your icon PNG at `~/.notification-hooks/assets/<tool>-logo.png` (1024x1024 or larger keeps downsampled icons crisp).

```sh
ASSETS="$HOME/.notification-hooks/assets"
APP_DST="$HOME/.notification-hooks/claude-notifier.app"
APP_SRC="$(brew --prefix terminal-notifier)/terminal-notifier.app"

mkdir -p "$ASSETS"
# Replace ~/path/to/your.png with your source file:
cp ~/path/to/your.png "$ASSETS/claude-logo.png"

# Generate a macOS iconset (multiple resolutions) and convert to .icns.
ICONSET="$ASSETS/claude.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" "$ASSETS/claude-logo.png" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  half=$((size / 2))
  if [ "$half" -ge 16 ]; then
    sips -z "$size" "$size" "$ASSETS/claude-logo.png" \
      --out "$ICONSET/icon_${half}x${half}@2x.png" >/dev/null
  fi
done
sips -z 1024 1024 "$ASSETS/claude-logo.png" \
  --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$ASSETS/claude.icns"

# Copy the upstream .app, swap the icon, rebrand.
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
cp "$ASSETS/claude.icns" "$APP_DST/Contents/Resources/Terminal.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.claude-notifier" \
  "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ClaudeNotifier" \
  "$APP_DST/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string \"Claude Notifier\"" \
  "$APP_DST/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName \"Claude Notifier\"" \
    "$APP_DST/Contents/Info.plist"

# Re-sign ad-hoc. Info.plist edits invalidate the upstream signature.
codesign --force --deep --sign - "$APP_DST"

# Register with LaunchServices so macOS discovers the icon.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DST"

# Flush the icon cache.
killall Dock NotificationCenter 2>/dev/null || true
```

The new bundle ID (`local.claude-notifier`) means macOS treats this as a separate app. Your Homebrew install of `terminal-notifier` is not modified and may still be upgraded freely. The bundle name is "claude-notifier" for historical reasons; rename to something tool-neutral if you prefer.

### 4. Configure Claude Code

Add the hooks block to `~/.claude/settings.json`. Merge into your existing config rather than overwriting:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "sh ~/.notification-hooks/notification.sh claude" }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "sh ~/.notification-hooks/stop.sh claude" }
        ]
      }
    ]
  }
}
```

### 5. Configure Codex

Add the hooks block to `~/.codex/hooks.json` (create the file if it doesn't exist). Codex's `PermissionRequest` event maps to Claude's `Notification`. Codex doesn't expose an idle-input event, so notifications only fire on permission prompts and turn endings.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "sh ~/.notification-hooks/notification.sh codex" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "sh ~/.notification-hooks/stop.sh codex" }
        ]
      }
    ]
  }
}
```

Also enable the feature flag in `~/.codex/config.toml`:

```toml
[features]
hooks = true
```

(An older spelling, `codex_hooks = true`, was previously documented but is now deprecated. Use `hooks = true`.)

(See https://developers.openai.com/codex/hooks for the full Codex hooks reference.)

### 6. Grant notification permission

The first time the branded bundle fires, macOS may suppress the notification because the new bundle ID has no permission entry yet. To force the prompt, run:

```sh
~/.notification-hooks/claude-notifier.app/Contents/MacOS/terminal-notifier \
  -title "Setup test" -message "Click Allow on the macOS prompt"
```

Open System Settings, Notifications, find "Claude Notifier" in the list, and toggle Allow Notifications on. Set the style to Alerts if you want notifications to stay on screen until dismissed.

### 7. Verify

Restart whichever tool you configured so it re-reads its settings file, then end a turn. You should see a "Claude finished" or "Codex finished" notification with your icon. Click it to confirm it focuses your terminal or IDE.

## Configuration

### Toggles

Both tools share the same toggle pattern, with separate prefixes so you can mute one tool without affecting the other.

| Variable | Effect |
|---|---|
| `CLAUDE_NOTIFICATIONS` | Master switch for Claude hooks. |
| `CLAUDE_NOTIFICATIONS_INPUT` | Disables only Claude's "waiting" notification. |
| `CLAUDE_NOTIFICATIONS_STOP` | Disables only Claude's "finished" notification. |
| `CODEX_NOTIFICATIONS` | Master switch for Codex hooks. |
| `CODEX_NOTIFICATIONS_INPUT` | Disables only Codex's permission-request notification. |
| `CODEX_NOTIFICATIONS_STOP` | Disables only Codex's "finished" notification. |

All default to "on". Disable values (case insensitive): `off`, `0`, `false`, `no`.

### Scopes

Hooks resolve toggle values across these locations, in order of decreasing precedence:

1. Shell environment variable
2. `<project>/.<tool>/<config>` (project local config, then committed config)
3. `~/.<tool>/<config>` (global local config, then global config)

Where `<tool>` is `claude` or `codex` based on which hook fired, and `<config>` is:
- Claude: `settings.local.json`, then `settings.json`
- Codex: `hooks.json`, then `config.toml`

The first non-empty value wins. Empty or missing values fall through to the next layer.

### Examples

Disable Claude's noisy Stop hook in one repo, kept private to your checkout:

```json
// <repo>/.claude/settings.local.json
{
  "env": {
    "CLAUDE_NOTIFICATIONS_STOP": "off"
  }
}
```

Disable all Codex notifications in a specific repo (committed for the team):

```json
// <repo>/.codex/hooks.json
{
  "env": {
    "CODEX_NOTIFICATIONS": "off"
  }
}
```

Disable everything globally, then enable per project as needed:

```json
// ~/.claude/settings.json
{
  "env": {
    "CLAUDE_NOTIFICATIONS": "off"
  }
}
```

```json
// <opted-in repo>/.claude/settings.json
{
  "env": {
    "CLAUDE_NOTIFICATIONS": "on"
  }
}
```

## Customization

### Change a tool's icon

Replace `~/.notification-hooks/assets/<tool>-logo.png` with a new PNG (`claude-logo.png` for Claude, `codex-logo.png` for Codex), then re-run the iconset generation, .icns conversion, copy into the appropriate `.app` bundle, re-sign, and flush the icon cache. The block of commands in installation step 3 is the same script to run; substitute the tool name in the paths.

After the icon swap, you may need to grant notification permission again under the new bundle name in System Settings → Notifications, and the cache flush (`killall Dock NotificationCenter`) ensures the new icon is picked up immediately.

### Change the sounds

In `notification.sh` and `stop.sh`, change the `-sound` flag values. Available sounds are the files in `/System/Library/Sounds/` without the `.aiff` extension: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink.

### Change the layout

The current layout:
- Title: `<Tool> is waiting` or `<Tool> finished`
- Subtitle: short app name (e.g. "VS Code")
- Message body: multi-line, holds project, branch, and message

Move pieces around by editing the `-title`, `-subtitle`, and `-message` arguments at the bottom of each hook script. macOS truncates subtitles aggressively (around 30 to 40 characters), so any field that could be long should live in the message body.

### Add a new terminal or IDE to the brand-name mapping

Edit the `bundle_to_appname` case block in `_lib.sh`. Find the bundle ID by running this while that app is in focus:

```sh
osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true'
```

### Add a new tool

To wire in a third assistant beyond Claude and Codex:
1. Add a new case to `resolve_tool` in `_lib.sh` returning the new tool's name.
2. Add a new case to `tool_title` in `_lib.sh` for branded titles.
3. Add a new case to `notifier_bin` in `_lib.sh` returning the path to that tool's `.app` bundle.
4. Extend `get_setting`'s tool-specific file list.
5. Build a branded `.app` bundle for that tool (installation step 3 with a new bundle ID like `local.<tool>-notifier`).
6. Wire that tool's hooks config to call `sh ~/.notification-hooks/<script>.sh <tool>`.

### Tone down the Stop hook

Turn-end pings can get noisy in interactive sessions. Two patterns help:

1. **Idle gate**: only fire if the system has been idle for over 30 seconds. Add this at the top of `stop.sh`, after the `should_notify` line:

   ```sh
   idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
   [ "${idle:-0}" -lt 30 ] && exit 0
   ```

2. **Long-turn gate**: only fire if the turn took more than 20 seconds. Track turn start in a per-session state file like the statusline does, and compare against current time.

## How it works

### Calling-app detection (the process-tree walk)

`$TERM_PROGRAM` is unreliable because VS Code, Cursor, and Windsurf all report `vscode`. Each has a distinct macOS bundle ID, though, so the hook walks up the parent process chain starting from its own PID:

```
hook process (PID N)
  shell (PID N-1)
    AI assistant process (claude / codex)
      Terminal helper process
        Terminal GUI process  ← first one with a bundle ID
```

For each PID, `lsappinfo info -only bundleid <pid>` returns the bundle ID or an empty value. The first non-empty value is the GUI ancestor, which is the app the user thinks of as "where I'm running the assistant".

### Settings file resolution

`get_setting` in `_lib.sh` walks the hook's `cwd` upward looking for a `.claude/` or `.codex/` directory (preferring the calling tool's). For each scope, it pulls the env value with `jq` (JSON configs) or a minimal `awk` parser (Codex's optional TOML configs) and returns the first non-empty match. This avoids depending on either tool propagating env vars into hook subprocesses, which neither tool documents as a guarantee.

### Multi-line message body

`terminal-notifier`'s `-message` flag accepts real LF characters and passes them through to the macOS notification API. The hook builds the body with `printf '%s\n%s'` (literal newlines), not `\n` escape sequences. The result wraps to multiple lines when expanded in Notification Center.

### Re-signing after Info.plist edits

macOS Gatekeeper rejects apps whose resource hashes don't match the signature. Editing `Contents/Info.plist` changes the hash, so the original Homebrew signature becomes invalid. `codesign --force --deep --sign -` re-signs the bundle with an ad-hoc identity, which Gatekeeper accepts for locally-built apps.

### LaunchServices registration

After `cp -R`, the new bundle exists on disk but macOS hasn't catalogued it. `lsregister -f` forces a fresh registration, which makes the icon discoverable and gives the app a permissions entry.

### Click to focus (tab or window)

When you click the notification, `terminal-notifier`'s `-execute` flag runs `focus.sh <session_id>`. The script reads cached state from `~/.notification-hooks-state/<session_id>.{bundle,tty,cwd}` and runs app-specific AppleScript.

#### Granularity of focus per app

| App | What gets focused | How |
|---|---|---|
| iTerm2 | The exact tab whose pty matches the cached TTY | AppleScript walks windows, tabs, and sessions, matches by `tty` property |
| Apple Terminal | The exact tab whose `tty` matches | AppleScript walks windows and tabs, matches by `tty` property |
| VS Code, Cursor, Windsurf, Antigravity | The window whose title contains the project name | System Events enumerates windows of the right process, uses `AXRaise` to surface the match |
| Anything else | Just the app | Plain `tell application id "..." to activate` |

The VS Code-family case uses **System Events**, which requires Accessibility permission. macOS prompts the first time the AppleScript runs; allow `terminal-notifier` (or whichever app the prompt names) in System Settings, Privacy & Security, Accessibility.

The TTY is cached per session in `<session_id>.tty` (typically 11 to 14 bytes per file) the same way the bundle ID is. Both are stable for the lifetime of a Claude/Codex session.

#### Why VS Code tab focus stops at the window

In iTerm2 and Apple Terminal, each terminal tab is a real macOS UI element with a documented scripting API. The hook can ask "find the tab whose `tty` is `/dev/ttys011` and select it", and the terminal app obliges.

In VS Code, Cursor, Windsurf, and Antigravity, the integrated terminal tabs are not macOS UI elements. They are HTML rendered inside an Electron webview, invisible to AppleScript, System Events, and every CLI flag the editor exposes. The same is true of editor tabs, side panel tabs, and every other in-window UI: macOS cannot address them from outside.

As a result, the click handler can only get as far as bringing the correct VS Code window forward (which works correctly, matched by project name in the window title). VS Code then restores focus to whichever element was last focused inside that window: if that was an editor file, you land in the editor; if it was the integrated terminal, you land in the terminal. The hook cannot change that behavior without an installed extension.

If exact tab focus matters more than the simplicity of this setup, the standard pattern is to write a small VS Code extension that registers a `vscode://...` URI handler and exposes the integrated terminal API. The hook would then `open vscode://...` on click. That is outside the scope of this directory but the README contributors are happy to take a PR.

### Background execution of `terminal-notifier`

Each hook wraps its `terminal-notifier` call in a backgrounded subshell:

```sh
( "$NOTIFIER_BIN" -title "..." -message "..." >/dev/null 2>&1 ) &
```

The parentheses spawn a subshell, the `&` backgrounds it, and the hook script continues to its own exit. The notifier subprocess keeps running independently and renders the notification a moment later. This matters because both Claude and Codex wait for hooks to exit before continuing. Backgrounding pushes terminal-notifier's ~260 ms startup off the critical path.

When the orphaned subshell finishes, macOS reparents it to launchd (PID 1), which reaps it normally. No zombies, no SIGHUP issues, because SIGHUP is sent on interactive shell exit, not on script exit.

Measured timing on an Apple Silicon Mac:

| Phase | Wall-clock cost |
|---|---|
| Hook starts, sources `_lib.sh`, parses stdin, resolves settings | ~50 to 100 ms |
| Subshell spawn + hook exit | ~5 ms |
| Tool continues from here (hook has returned) | |
| `terminal-notifier` runs in background, calls Notification Center | ~260 ms |
| Notification appears | total ~310 to 360 ms after the event |

The first turn of a new session pays an additional ~60 ms to walk the process tree; every turn after that hits the on-disk cache.

### What "background" means here (and what does not survive a reboot)

The word "background" in `( cmd ) &` is the shell-level meaning, not the macOS daemon meaning:

| Concept | Lives for | Persists across reboot? | Examples |
|---|---|---|---|
| Shell background process (`cmd &`) | One execution, milliseconds to seconds | No | The `terminal-notifier` subshell each hook fires |
| macOS background service (LaunchAgent, LaunchDaemon) | Until manually stopped or system shuts down | Yes, restarts automatically | Spotify Helper, Dropbox |

This setup uses only the first kind. There is no daemon, no LaunchAgent, no `launchctl` entry, no PID file. Nothing is "running in the background" between notifications. After a reboot you do nothing; the next turn fires the hook and spawns the subshell fresh.

What survives a reboot is the configuration and assets on disk, not any running process:

| Asset | Survives reboot? |
|---|---|
| Hook scripts (`*.sh`) | Yes (plain files) |
| `~/.claude/settings.json` and `~/.codex/hooks.json` | Yes (plain files) |
| `claude-notifier.app` bundle | Yes (plain directory) |
| Notification permission grant for "Claude Notifier" | Yes (macOS notification database) |
| LaunchServices registration of the bundle | Yes (macOS cache) |
| Bundle-detection cache (`~/.notification-hooks-state/*.bundle`) | Yes, but keyed by `session_id`, so old entries are inert |

### Running multiple sessions concurrently

You can run as many sessions of either tool as you want, in parallel. Each fires its own hooks independently. No shared state, no global lock.

| Concern | What actually happens |
|---|---|
| Two sessions finish a turn at the same instant | Two hook scripts start in parallel. Each spawns its own notifier subshell. macOS Notification Center stacks the notifications. |
| Both sessions write to the bundle cache | Each has a unique `session_id`, so each writes to its own `~/.notification-hooks-state/<session_id>.bundle` file. |
| Both sessions read the same `settings.json` | Modern filesystems and macOS's page cache make concurrent reads effectively free. |
| Each session walks its own process tree | One session in iTerm2 and another in VS Code each correctly detects their respective parent. |
| Per-tool toggles | Setting `CLAUDE_NOTIFICATIONS_STOP=off` in a `.claude/settings.json` only affects Claude sessions. Codex sessions in the same project keep firing because they look in `.codex/` for their toggles. |

No measurable contention up to about ten concurrent sessions per tool.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| No notification appears at all | First-run permission not granted | Look for "Claude Notifier" in System Settings, Notifications, and toggle Allow on. |
| Notification appears but icon is wrong | macOS icon cache stale | `killall Dock NotificationCenter`, then trigger another notification. |
| Notification appears but click does nothing | New app needs a separate permission grant | Same fix as the "no notification" row. |
| Click opens Script Editor or Terminal instead of the right app | An older osascript-based notification is still in Notification Center | Clear Notification Center. Newly fired notifications from the branded bundle route correctly. |
| Click brings VS Code (or Antigravity, Cursor, Windsurf) to the front but doesn't switch to the right window | Accessibility permission not granted | Open System Settings, Privacy & Security, Accessibility, and toggle on the app `terminal-notifier` (or `osascript`) when macOS prompts. After that, window matching works. |
| Click switches to the right VS Code window but stays on the editor, not the terminal tab | Expected behavior, not a bug | VS Code's integrated terminal tabs are inside the Electron webview and unreachable from outside the app. The hook focuses the window; VS Code itself decides which inner element gets keyboard focus. See "Why VS Code tab focus stops at the window" above. The standard workaround is a VS Code extension. |
| Click activates the app but stays on the wrong iTerm2 / Terminal tab | TTY state file missing or stale | Verify `~/.notification-hooks-state/<session_id>.tty` exists and contains a real `/dev/ttys...` path. If empty, the script couldn't find a TTY in the parent process tree, which happens when Claude/Codex was launched headless. |
| Notification title is wrong tool ("Claude" when Codex fired) | Tool arg missing from the hook command | Make sure the command in each tool's config ends with `claude` or `codex`. |
| Hook fires for Claude but not Codex | Codex feature flag not enabled | Add `hooks = true` under `[features]` in `~/.codex/config.toml`. |
| Toggle has no effect | Wrong env var prefix for the tool | Claude uses `CLAUDE_NOTIFICATIONS_*`. Codex uses `CODEX_NOTIFICATIONS_*`. Setting one does not affect the other. |
| Codex config in TOML doesn't honour the toggle | Parser is best-effort for TOML | Use the JSON form (`~/.codex/hooks.json`) for reliable env block reads. |
| `codesign` fails with "resource fork, Finder information, or similar detritus not allowed" | Extended attributes copied from Homebrew install | `xattr -cr ~/.notification-hooks/claude-notifier.app`, then re-sign. |
| Wrong notifier path on Intel Mac | Homebrew prefix differs | Adjust the `brew --prefix terminal-notifier` resolution in installation step 3. The runtime `NOTIFIER_BIN` path stays the same. |

## Uninstall

```sh
# Remove the hook directory and state.
rm -rf ~/.notification-hooks
rm -rf ~/.notification-hooks-state

# Drop "hooks" keys from ~/.claude/settings.json and ~/.codex/hooks.json
# by hand, or replace the whole file.

# Optional: uninstall terminal-notifier if nothing else uses it.
brew uninstall terminal-notifier

# Optional: forget the LaunchServices registration.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u ~/.notification-hooks/claude-notifier.app 2>/dev/null || true
```

## Attribution and licensing

- `terminal-notifier` is BSD licensed: https://github.com/julienXX/terminal-notifier
- The scripts in this directory are not derived from `terminal-notifier`'s source, only from its `.app` bundle structure, which is shipped under the same BSD license.
- The icon PNG is your own. Replace `claude-logo.png` with whatever you want to brand your notifier as.
