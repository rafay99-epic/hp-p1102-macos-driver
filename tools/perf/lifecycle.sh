#!/bin/bash
# Long-running PrinterBar checks the 60 s scenarios in perf.sh can't show:
#   cupsd   does cupsd (which exits after ~60 s without requests) get to exit
#           while the app sits idle in the menu bar?
#   leak    memory footprint after the popover is opened and closed 25 times
#   launch  median time from exec to first status, over 5 launches
# Uses a throwaway queue, never the real one. Needs Accessibility access for
# the terminal (clicks the menu bar item through System Events).
# Usage: [APP=path/to/PrinterBar] tools/perf/lifecycle.sh
set -euo pipefail
APP=${APP:-build/PrinterBar.app/Contents/MacOS/PrinterBar}
Q=PrinterBar_Perf
[ -x "$APP" ] || { echo "build the app first: make app" >&2; exit 1; }
pgrep -f "$APP" > /dev/null && { echo "PrinterBar is already running; quit it first" >&2; exit 1; }
trap 'pkill -TERM -f "$APP" 2>/dev/null || true; lpadmin -x "$Q" 2>/dev/null || true' EXIT
lpadmin -p "$Q" -v ipp://127.0.0.1:9/perf -P driver/ppd/HP-LaserJet-P1102.ppd -o printer-is-shared=false 2> /dev/null
cupsdisable "$Q"
echo "app: $APP"

launch() { PRINTERBAR_PERF=1 PRINTERBAR_QUEUE=$Q "$APP" 2> "${1:-/dev/null}" & sleep 2; pgrep -f "^$APP" | head -1; }
stop() { kill -TERM "$1"; wait 2> /dev/null || true; }
foot() { footprint -p "$1" 2> /dev/null | awk '/phys_footprint:/ {print $2 $3; exit}'; }
click() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1) to click menu bar item 1 of menu bar 1" > /dev/null; }

# cupsd: nothing else may talk to CUPS while this waits (pgrep doesn't).
pid=$(launch)
t=0
while pgrep -x cupsd > /dev/null && [ $t -lt 120 ]; do sleep 1; t=$((t + 1)); done
if pgrep -x cupsd > /dev/null; then echo "cupsd   still running after 120 s idle"; else echo "cupsd   exited ${t} s into the idle period"; fi
stop "$pid"

pid=$(launch)
before=$(foot "$pid")
for _ in $(seq 25); do click "$pid"; sleep 0.4; click "$pid"; sleep 0.4; done
sleep 2
echo "leak    footprint $before before, $(foot "$pid") after 25 open/close cycles"
stop "$pid"

times=()
for i in 1 2 3 4 5; do
  start=$(python3 -c 'import time; print(int(time.time() * 1000))')
  pid=$(launch /tmp/printerbar-launch.txt)
  ready=$(awk '/ready_epoch_ms/ {print $3}' /tmp/printerbar-launch.txt)
  times+=($((ready - start)))
  stop "$pid"
done
echo "launch  median $(printf '%s\n' "${times[@]}" | sort -n | sed -n 3p) ms  (runs: ${times[*]})"
