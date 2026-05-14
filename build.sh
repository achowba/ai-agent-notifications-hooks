#!/usr/bin/env bash
###############################################################################
# build.sh
#
# Rebuilds the branded terminal-notifier .app bundles from the source PNGs in
# ./assets/. Use this after a fresh clone, after changing an icon, or after
# upgrading Homebrew's terminal-notifier.
#
# Usage:
#   ./build.sh                 # build both Claude and Codex bundles
#   ./build.sh claude          # build only the Claude bundle
#   ./build.sh codex           # build only the Codex bundle
#
# Prerequisites:
#   - macOS 12+
#   - Homebrew with `terminal-notifier` installed (`brew install terminal-notifier`)
#   - Xcode command-line tools (`xcode-select --install`) for sips, iconutil, codesign
###############################################################################
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$ROOT/assets"
APP_SRC="$(brew --prefix terminal-notifier)/terminal-notifier.app"

if [ ! -d "$APP_SRC" ]; then
  echo "ERROR: terminal-notifier not found at $APP_SRC" >&2
  echo "Install it with: brew install terminal-notifier" >&2
  exit 1
fi

# Build a single bundle.
# Args: $1 = tool name ("claude" | "codex")
build_bundle() {
  local tool="$1"
  local logo="$ASSETS/${tool}-logo.png"
  local icns="$ASSETS/${tool}.icns"
  local iconset="$ASSETS/${tool}.iconset"
  local app_dst="$ROOT/${tool}-notifier.app"
  local bundle_id="local.${tool}-notifier"
  local display_name
  case "$tool" in
    claude)  display_name="Claude Notifier" ;;
    codex)   display_name="Codex Notifier" ;;
    *)       echo "Unknown tool: $tool" >&2; return 1 ;;
  esac
  local internal_name="${display_name// /}"

  if [ ! -f "$logo" ]; then
    echo "ERROR: $logo not found. Drop a 1024x1024 PNG at that path." >&2
    return 1
  fi

  echo "==> Building $app_dst from $logo"

  # 1. Generate the iconset.
  rm -rf "$iconset"
  mkdir -p "$iconset"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$logo" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    local half=$((size / 2))
    if [ "$half" -ge 16 ]; then
      sips -z "$size" "$size" "$logo" --out "$iconset/icon_${half}x${half}@2x.png" >/dev/null
    fi
  done
  sips -z 1024 1024 "$logo" --out "$iconset/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset" -o "$icns"

  # 2. Copy the upstream .app and rebrand it.
  rm -rf "$app_dst"
  cp -R "$APP_SRC" "$app_dst"
  cp "$icns" "$app_dst/Contents/Resources/Terminal.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_dst/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $internal_name" "$app_dst/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string \"$display_name\"" "$app_dst/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName \"$display_name\"" "$app_dst/Contents/Info.plist"

  # 3. Strip any quarantine attribute that may have travelled with cp -R,
  # then re-sign ad-hoc. Info.plist edits invalidate the upstream signature.
  xattr -cr "$app_dst" 2>/dev/null || true
  codesign --force --deep --sign - "$app_dst"

  # 4. Register with LaunchServices so the icon is discoverable.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$app_dst"

  echo "    bundle id : $bundle_id"
  echo "    display   : $display_name"
  echo "    icon size : $(stat -f %z "$icns") bytes"
}

# Flush macOS icon cache so the new icons appear immediately. Safe to skip if
# you only want to rebuild without touching the live UI.
flush_caches() {
  echo "==> Flushing icon cache (killall Dock NotificationCenter)"
  killall Dock 2>/dev/null || true
  killall NotificationCenter 2>/dev/null || true
}

main() {
  case "${1:-all}" in
    all)
      build_bundle claude
      build_bundle codex
      ;;
    claude|codex)
      build_bundle "$1"
      ;;
    *)
      echo "Usage: $0 [all|claude|codex]" >&2
      exit 1
      ;;
  esac
  flush_caches
  echo "==> Done. Test with:"
  echo "    sh notification.sh claude <<<'{\"message\":\"test\",\"cwd\":\"'$PWD'\"}'"
}

main "$@"
