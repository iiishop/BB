#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
export DISPLAY=:99
Xvfb :99 -screen 0 1600x1000x24 > real-client-data/xvfb2.log 2>&1 &
XVFB_PID=$!
sleep 1
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 BB_SESSION_FILE="$PWD/real-client-data/run/session.json"
./BB-client/client/build/linux/x64/release/bundle/bb_mobile > real-client-data/app2.log 2>&1 &
APP_PID=$!
cleanup() { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; kill "$XVFB_PID" 2>/dev/null || true; wait "$XVFB_PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 8
WID=$(xdotool search --name '^BB$' | head -1)
[ -n "$WID" ] || { echo no-window; exit 1; }
shot() { import -window root "real-client-data/$1.raw.png"; convert "real-client-data/$1.raw.png" -crop "$2" +repage "real-client-data/$1.png"; rm -f "real-client-data/$1.raw.png"; }
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
xdotool windowsize --sync "$WID" 1440 900; xdotool windowmove "$WID" 0 0; sleep 2
click 46 155
shot shot-real2-feed-wide 1440x900+0+0
click 600 175
shot shot-real2-detail-wide 1440x900+0+0
xdotool windowsize --sync "$WID" 390 844; xdotool windowmove "$WID" 0 0; sleep 3
shot shot-real2-detail-phone 390x844+0+0
click 180 715
xdotool type --delay 25 'phone typed comment'
sleep 2
shot shot-real2-detail-phone-typed 390x844+0+0
xdotool windowsize --sync "$WID" 1024 768; xdotool windowmove "$WID" 0 0; sleep 3
shot shot-real2-detail-fold-typed 1024x768+0+0
echo '--- log ---'; tail -5 real-client-data/app2.log
