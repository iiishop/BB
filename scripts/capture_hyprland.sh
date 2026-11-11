#!/usr/bin/env bash
# Usage: APP_BIN=/absolute/path/to/bundle/app OUT_FILE=/tmp/flutter-window.png ./capture_hyprland.sh
# Designed to avoid broad pkill and avoid full-screen capture.
set -Eeuo pipefail

: "${APP_BIN:?Set APP_BIN to the exact built Linux Flutter executable}"
: "${OUT_FILE:?Set OUT_FILE to desired PNG path}"
[ -x "$APP_BIN" ] || { echo "APP_BIN not executable: $APP_BIN" >&2; exit 2; }
for cmd in hyprctl jq grim; do command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 3; }; done
mkdir -p "$(dirname "$OUT_FILE")"
LOG_FILE="${OUT_FILE%.*}.app.log"
"$APP_BIN" >"$LOG_FILE" 2>&1 &
app_pid=$!
cleanup() {
  # Only signal the exact child started by this script; do not pkill by name/pattern.
  if kill -0 "$app_pid" 2>/dev/null; then kill "$app_pid" 2>/dev/null || true; fi
  wait "$app_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

geometry=''
for _ in $(seq 1 50); do
  geometry="$(hyprctl clients -j | jq -r --argjson pid "$app_pid" '.[] | select(.pid == $pid) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"' | head -n 1)"
  [ -n "$geometry" ] && break
  kill -0 "$app_pid" 2>/dev/null || { echo "App quit early; see $LOG_FILE" >&2; exit 4; }
  sleep 0.2
done
[ -n "$geometry" ] || { echo "Window for exact PID $app_pid not found; do not capture other windows" >&2; exit 5; }
# Wait briefly for first frame. Replace with an app-specific ready signal if possible.
sleep 1
grim -g "$geometry" "$OUT_FILE"
[ -s "$OUT_FILE" ] || { echo "Screenshot empty" >&2; exit 6; }
echo "Captured exact process PID $app_pid window geometry [$geometry] to $OUT_FILE"
echo "Application log: $LOG_FILE"
