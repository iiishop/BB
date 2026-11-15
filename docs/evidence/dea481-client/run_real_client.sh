#!/usr/bin/env bash
set -u
cd "$(dirname "$0")"
mkdir -p real-client-data
export DISPLAY=:99
Xvfb :99 -screen 0 1600x1000x24 > real-client-data/xvfb.log 2>&1 &
XVFB_PID=$!
sleep 1
export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 BB_SESSION_FILE="$PWD/real-client-data/run/session.json"
./BB-client/client/build/linux/x64/release/bundle/bb_mobile > real-client-data/app.log 2>&1 &
APP_PID=$!
cleanup() {
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  kill "$XVFB_PID" 2>/dev/null || true
  wait "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 8
WID=$(xdotool search --name '^BB$' | head -1)
echo "WID=$WID geom=$(xdotool getwindowgeometry "$WID" | tr '\n' ' ')"
[ -n "$WID" ] || { echo "no window"; exit 1; }
shot() {
  import -window root "real-client-data/$1.raw.png"
  convert "real-client-data/$1.raw.png" -crop "$2" +repage "real-client-data/$1.png"
  rm -f "real-client-data/$1.raw.png"
}
click() { xdotool mousemove "$1" "$2" click 1; sleep 2; }
xdotool windowsize --sync "$WID" 1440 900
xdotool windowmove "$WID" 0 0
sleep 2
click 46 155
shot shot-real-space-wide 1440x900+0+0
click 700 150
shot shot-real-detail-wide 1440x900+0+0
# Close detail.
click 706 54
sleep 1
# Narrow window: same Space state, touch bottom bar.
xdotool windowsize --sync "$WID" 390 844
xdotool windowmove "$WID" 0 0
sleep 3
shot shot-real-space-phone 390x844+0+0
# Open the first post's body in the phone layout.
click 200 250
sleep 2
shot shot-real-detail-phone 390x844+0+0
# Type into the comment composer, then expand to the simulated fold width.
click 200 760
xdotool type --delay 20 'fold state check'
sleep 2
xdotool windowsize --sync "$WID" 1024 768
xdotool windowmove "$WID" 0 0
sleep 3
shot shot-real-detail-fold 1024x768+0+0
echo "--- app log ---"
tail -10 real-client-data/app.log
ls -l real-client-data/shot-real-*.png
