#!/bin/sh
# Times the driver filter on a 10-page A4 job (600 dpi, about 33 MB of gray
# raster per page) and prints a hash of its 1-bit output, so an optimization
# can be checked for byte-identical results.
# Usage: tools/perf/filter-bench.sh [runs]
set -eu
RUNS=${1:-5}
B=build/bench
mkdir -p "$B"
make -s build/foo2zjs
[ -f "$B/job.ras" ] || {
  swift tools/testpage.swift "$B/page.pdf" A4 > /dev/null
  sed 's#/Library/Printers/HP-P1102/filter/rastertozjs#/usr/bin/true#' driver/ppd/HP-LaserJet-P1102.ppd > "$B/bench.ppd"
  cupsfilter -p "$B/bench.ppd" -m application/vnd.cups-raster -n 10 "$B/page.pdf" > "$B/job.ras" 2> /dev/null
}
printf '#!/bin/sh\nexec cat\n' > "$B/passthrough" && chmod +x "$B/passthrough"
CFLAGS="-O2 -Wall -Wextra -Werror -Wno-deprecated-declarations"
clang $CFLAGS -DFOO2ZJS="\"$PWD/$B/passthrough\"" -o "$B/halftone" driver/src/rastertozjs.c -lcups
clang $CFLAGS -DFOO2ZJS="\"$PWD/build/foo2zjs\"" -o "$B/full" driver/src/rastertozjs.c -lcups

best() { # command... -> fastest user+sys seconds over $RUNS runs
  i=0; best=999
  while [ $i -lt "$RUNS" ]; do
    t=$(/usr/bin/time -p sh -c '"$@" > /dev/null 2>&1' _ "$@" 2>&1 | awk '/^(user|sys)/ {s += $2} END {print s}')
    best=$(echo "if ($t < $best) $t else $best" | bc); i=$((i + 1))
  done
  echo "$best"
}
echo "10 pages, best of $RUNS runs (CPU seconds):"
echo "  halftone only     $(best "$B/halftone" 1 u t 1 "" "$B/job.ras")"
echo "  halftone+foo2zjs  $(best "$B/full" 1 u t 1 "" "$B/job.ras")"
"$B/halftone" 1 u t 1 "" "$B/job.ras" 2> /dev/null | shasum -a 256 | awk '{print "  PBM sha256        " $1}'
"$B/full" 1 u t 1 "" "$B/job.ras" 2> /dev/null | LC_ALL=C sed '/^@PJL SET JOBATTR/d' | shasum -a 256 | awk '{print "  ZjStream sha256   " $1}'
