#!/usr/bin/env bash
# capture-demo.sh -- launch Majik's Music Studio and set it up for an
# end-to-end demo recording. See demo/DEMO-SCRIPT.md for the beats and
# HANDOFF-demo.md for the runbook.
#
# WHAT THIS DOES (safe, no backends needed):
#   - launches the app foreground, finds it by PID (not by name: same-named
#     processes alias under System Events),
#   - repositions/sizes the window fully on the main screen,
#   - gives you helpers to drive the app by keystroke and to grab frames.
#
# WHAT IT DOES NOT DO:
#   - it does NOT enable audio. Audible playback is your attended step: launch
#     with MAJIKS_TEST_AUDIBLE=1 yourself, on monitors you control.
#   - it does NOT auto-run the beats. The per-beat drive below is a scaffold:
#     generation and Sterling timing depend on your live backends, so tune the
#     waits and run it interactively (or just use it to place the window and
#     screen-record by hand, which is what most good demos do).
#
# Usage:
#   ./demo/capture-demo.sh /Applications/Majiks\ Music\ Studio.app
#   (or pass the .app you built; defaults to /Applications)

set -euo pipefail

APP="${1:-/Applications/Majiks Music Studio.app}"
OUT_DIR="${DEMO_OUT:-$HOME/Desktop/majiks-demo-capture}"
mkdir -p "$OUT_DIR"

if [ ! -d "$APP" ]; then
  echo "App not found: $APP" >&2
  echo "Pass the path to the built .app as the first argument." >&2
  exit 1
fi

echo "Launching: $APP"
# For an AUDIBLE take, launch yourself with:  MAJIKS_TEST_AUDIBLE=1 open -a "$APP"
open "$APP"

# Find the PID (drive by PID; System Events aliases same-named processes).
PID=""
for _ in $(seq 1 40); do
  PID="$(pgrep -f 'MajiksMusicStudio' | head -1 || true)"
  [ -n "$PID" ] && break
  sleep 0.25
done
if [ -z "$PID" ]; then echo "Could not find the app PID." >&2; exit 1; fi
echo "App PID: $PID"

# Place the window fully on the main screen (belt-and-suspenders; the app also
# clamps itself at launch). Drives by unix id so we hit this exact process.
osascript <<OSA || true
tell application "System Events"
  set proc to first process whose unix id is ${PID}
  set frontmost of proc to true
  try
    set position of window 1 of proc to {80, 60}
    set size of window 1 of proc to {1600, 1000}
  end try
end tell
OSA

echo "Window placed. App is frontmost."
echo
echo "Helpers (source this script or copy these):"
cat <<'HELP'
  # Send a keystroke to the app (drive the shortcuts from DEMO-SCRIPT.md):
  key()   { osascript -e "tell application \"System Events\" to keystroke \"$1\""; }
  combo() { osascript -e "tell application \"System Events\" to keystroke \"$1\" using $2"; }
     # combo "c" "{command down, option down}"   -> Cmd+Opt+C (Sterling dock)
     # key "r"                                    -> Revise the selection
     # key " "                                    -> Space (play/pause)

  # Grab a still frame of the whole screen (loop this while you demo):
  #   screencapture -x -o "$OUT_DIR/frame_$(date +%s%N).png"
  # Or capture a screen video with QuickTime (File > New Screen Recording),
  # or:  screencapture -v -V 360 "$OUT_DIR/demo.mov"   # 360s screen video
HELP

echo
echo "The beats are in demo/DEMO-SCRIPT.md. Recommended flow:"
echo "  1) start your screen recorder,"
echo "  2) walk the 6 beats by hand (or tune the waits below and drive them),"
echo "  3) stop the recorder; frames/video land in: $OUT_DIR"
echo
echo "Scaffold for driving beat 5 (Sterling) once your endpoint is set --"
echo "uncomment and tune the sleeps to your gateway's latency:"
cat <<'BEAT5'
  # osascript -e 'tell application "System Events" to keystroke "c" using {command down, option down}'  # open Sterling
  # sleep 1
  # osascript -e 'tell application "System Events" to keystroke "Make the outro sixteen bars longer and duck the bed under the vocal in the last chorus."'
  # osascript -e 'tell application "System Events" to key code 36'   # Return to send
  # sleep 30   # <- tune to your Sterling turn latency; watch the chips land
BEAT5
