#!/bin/sh
# Runs test pages through the real macOS print pipeline
# (cgpdftoraster -> rastertozjs -> foo2zjs) and checks the decoded ZjStream.
# No printer needed. Set PPD=/path/to/installed.ppd to test an installed driver.
set -eu

T=build/test
mkdir -p "$T"
if [ -z "${PPD:-}" ]; then
  PPD=$T/test.ppd
  sed "s#/Library/Printers/HP-P1102/filter/rastertozjs#$PWD/$T/rastertozjs#" \
    driver/ppd/HP-LaserJet-P1102.ppd > "$PPD"
fi

fail=0
check() { # label decoded-file grep-pattern
  if grep -q "$3" "$2"; then echo "  ok    $1"; else echo "  FAIL  $1 (no '$3')"; fail=1; fi
}

# render <name> <pdf> [cups options...]: PDF -> ZjStream -> decoded text
render() {
  name=$1 pdf=$2; shift 2
  cupsfilter -e -p "$PPD" -m printer/cupsfilter "$@" "$pdf" > "$T/$name.zjs" 2> "$T/$name.log" \
    || { echo "  FAIL  $name: cupsfilter failed, see $T/$name.log"; fail=1; return 1; }
  build/zjsdecode < "$T/$name.zjs" > "$T/$name.txt" 2>&1
  bytes=$(awk '/ZJT_JBIG_BID/ {bid=1} bid && /Data:/ {n+=$2; bid=0} END {print n+0}' "$T/$name.txt")
  if [ "$bytes" -gt 10000 ]; then echo "  ok    $name: $bytes bytes of page data"
  else echo "  FAIL  $name: only $bytes bytes of page data"; fail=1; fi
}

for size in A4:9 Letter:1 Legal:5; do
  name=${size%:*} code=${size#*:}
  echo "$name"
  swift tools/testpage.swift "$T/$name.pdf" "$name" > /dev/null
  render "$name" "$T/$name.pdf" -o PageSize="$name" || continue
  check "paper code $code" "$T/$name.txt" "ZJI_DMPAPER, $code "
  check "600 dpi" "$T/$name.txt" "ZJI_RESOLUTION_X, 600 "
  check "one page" "$T/$name.txt" "\[Page 1\]"
done

echo "Options (Density=5, TonerSave, Heavy)"
if render options "$T/A4.pdf" -o PageSize=A4 -o Density=5 -o TonerSave=True -o MediaType=Heavy; then
  check "density 5" "$T/options.txt" "DENSITY=5"
  check "toner save" "$T/options.txt" "ECONOMODE=ON"
  check "heavy paper" "$T/options.txt" "ZJI_DMMEDIATYPE, 262 "
fi

# CUPS runs filters with an almost empty environment inside a sandbox.
# Anything that only works because of this shell's PATH would break there.
echo "Empty environment"
cupsfilter -p "$PPD" -m application/vnd.cups-raster -o PageSize=A4 "$T/A4.pdf" > "$T/A4.ras" 2> /dev/null
filter=$(sed -n 's/^\*cupsFilter2: "[^ ]* [^ ]* [0-9]* \(.*\)"$/\1/p' "$PPD")
if env -i "$filter" 1 test test 1 "" "$T/A4.ras" > "$T/envi.zjs" 2> "$T/envi.log" && [ -s "$T/envi.zjs" ]; then
  echo "  ok    filter runs with env -i"
else
  echo "  FAIL  filter under env -i, see $T/envi.log"; fail=1
fi

[ $fail = 0 ] && echo "All checks passed." || { echo "Some checks failed."; exit 1; }
