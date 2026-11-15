#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
export DISPLAY=:100
Xvfb :100 -screen 0 1600x1000x24 > real-client-data/xvfb2.log 2>&1 &
XVFB_PID=$!
sleep 1
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 BB_SESSION_FILE="$PWD/real-client-data/run/session.json"
./BB-client/client/build/linux/x64/release/bundle/bb_mobile > real-client-data/app2.log 2>&1 &
APP_PID=$!
cleanup() { kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; kill "$XVFB_PID" 2>/dev/null || true; wait "$XVFB_PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 10
WID=$(xdotool search --name '^BB$' | head -1)
[ -n "$WID" ] || { echo no-window; exit 1; }
echo "start geom: $(xdotool getwindowgeometry $WID | tr '\n' ' ')"
shot() { import -window "$WID" "real-client-data/$1.png"; }
click() { xdotool mousemove --window "$WID" "$1" "$2" click 1; sleep 2; }
xdotool windowsize --sync "$WID" 1440 900; xdotool windowmove "$WID" 0 0; sleep 3
click 46 155
shot shot-real2-feed-wide
click 600 350
shot shot-real2-detail-wide
xdotool windowsize --sync "$WID" 390 844; xdotool windowmove "$WID" 0 0; sleep 3
shot shot-real2-detail-phone
click 180 715
xdotool type --delay 25 'phone typed comment'
sleep 2
shot shot-real2-detail-phone-typed
xdotool windowsize --sync "$WID" 1024 768; xdotool windowmove "$WID" 0 0; sleep 3
echo "fold geom: $(xdotool getwindowgeometry $WID | tr '\n' ' ')"
shot shot-real2-detail-fold-typed
echo '--- log ---'; tail -5 real-client-data/app2.log
