#!/bin/bash
# PrinterBar performance harness.
# Runs the release app against a throwaway CUPS queue (never the real one) and
# reports, per scenario: CPU (app, child processes, cupsd), context switches,
# memory, threads, IPP requests, spawned processes, refreshes and view updates.
# Usage: [APP=path/to/PrinterBar] tools/perf/perf.sh [seconds per scenario] [completed jobs in history]
# Wall-clock numbers (launch) swing with machine load; instructions retired,
# request/spawn/refresh counts and context switches do not.
set -euo pipefail
DUR=${1:-60}
HIST=${2:-300}
APP=${APP:-build/PrinterBar.app/Contents/MacOS/PrinterBar}
Q=PrinterBar_Perf
OUT=build/perf
mkdir -p "$OUT"
[ -x "$APP" ] || { echo "build the app first: make app" >&2; exit 1; }
pgrep -f "$APP" > /dev/null && { echo "PrinterBar is already running; quit it first" >&2; exit 1; }

cleanup() {
  pkill -TERM -f "$APP" 2>/dev/null || true
  cancel -a -x "$Q" 2>/dev/null || true
  lpadmin -x "$Q" 2>/dev/null || true
}
trap cleanup EXIT

# Stopped queue: jobs wait forever and nothing is sent anywhere.
lpadmin -p "$Q" -v ipp://127.0.0.1:9/perf -P driver/ppd/HP-LaserJet-P1102.ppd -o printer-is-shared=false
cupsdisable "$Q"
cupsaccept "$Q"
PDF=$OUT/blank.pdf
printf '%%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 595 842]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$PDF"
echo "Building history: $HIST completed jobs on $Q"
for i in $(seq "$HIST"); do lp -d "$Q" -t "history $i" "$PDF" > /dev/null; done
cancel -a "$Q"

secs() { awk -F: '{ if (NF == 2) print $1 * 60 + $2; else print $1 }'; }
cpu_of() { ps -o time= -p "$1" 2>/dev/null | secs || echo 0; }
cupsd_cpu() { local p; p=$(pgrep -x cupsd || true); [ -n "$p" ] && cpu_of "$p" || echo 0; }
ms() { awk "BEGIN { printf \"%d\", ($1) * 1000 }"; }

# app_ms: the app's own CPU during the measured window (launch excluded)
# child_ms: CPU of processes the app spawned (whole run)
# cupsd_ms: CPU cupsd spent during the window; cupsd: still running at the end
# ctxsw: voluntary context switches (whole run), a proxy for wakeups
# Minstr: millions of instructions retired by the app and its children (whole run)
echo "load average: $(sysctl -n vm.loadavg)  app: $APP"
printf '\n%-9s %7s %8s %8s %6s %7s %6s %7s %8s %4s %7s %5s %5s %7s %5s\n' scenario app_ms child_ms cupsd_ms cupsd Minstr ctxsw footpr peak_ft thr launch ipp spawn refresh views
run() { # name, setup command
  local name=$1 setup=$2 start ready app c0 c1 a0 a1
  eval "$setup"
  start=$(python3 -c 'import time; print(int(time.time()*1000))')
  PRINTERBAR_PERF=1 PRINTERBAR_QUEUE=$Q /usr/bin/time -l "$APP" 2> "$OUT/$name.txt" &
  sleep 2
  app=$(pgrep -f "^$APP" | head -1)
  [ "$name" = popover ] && osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app) to click menu bar item 1 of menu bar 1" > /dev/null
  c0=$(cupsd_cpu); a0=$(cpu_of "$app")
  sleep "$DUR"
  c1=$(cupsd_cpu); a1=$(cpu_of "$app")
  local up; up=$(pgrep -x cupsd > /dev/null && echo up || echo exited)
  local foot thr
  foot=$(footprint -p "$app" 2>/dev/null | awk '/phys_footprint:/ {print $2 $3; exit}')
  thr=$(($(ps -M -p "$app" | wc -l) - 1))
  kill -TERM "$app"; wait || true
  local f=$OUT/$name.txt total peak launch ipp spawn refresh views ctx
  total=$(awk '/ user / {print $3 + $5}' "$f")
  ctx=$(awk '/voluntary context switches/ && !/involuntary/ {print $1}' "$f")
  peak=$(awk '/peak memory footprint/ {printf "%.1fM", $1 / 1048576}' "$f")
  ready=$(awk '/ready_epoch_ms/ {print $3}' "$f")
  launch=$([ -n "$ready" ] && echo "$((ready - start))ms" || echo -)
  ipp=$(awk '/^PERF ipp\.[^ ]* / && $2 !~ /\.us$/ {n += $3} END {print n + 0}' "$f")
  spawn=$(awk '/^PERF spawn\./ {n += $NF} END {print n + 0}' "$f")
  local instr; instr=$(awk '/instructions retired/ {printf "%d", $1 / 1000000}' "$f")
  refresh=$(awk '$2 == "refresh" {print $3}' "$f")
  views=$(awk '$2 == "body.root" {print $3}' "$f")
  printf '%-9s %7s %8s %8s %6s %7s %6s %7s %8s %4s %7s %5s %5s %7s %5s\n' "$name" "$(ms "$a1 - $a0")" \
    "$(ms "$total - $a1")" "$(ms "($c1 < $c0) ? $c1 : $c1 - $c0")" "$up" "$instr" "$ctx" "$foot" "$peak" "$thr" "$launch" \
    "$ipp" "$spawn" "${refresh:-0}" "${views:-0}"
}

run idle    "cancel -a $Q"
run queued  "for i in 1 2 3; do lp -d $Q -t queued-\$i $PDF > /dev/null; done"
run popover "cancel -a $Q"
echo
echo "Per-scenario counters: $OUT/<scenario>.txt (PERF lines). cupsd running after: $(pgrep -x cupsd > /dev/null && echo yes || echo no)"
