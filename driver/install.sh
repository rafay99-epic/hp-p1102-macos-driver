#!/bin/sh
# Installs the driver and creates the print queue. Needs root.
# Used by `sudo make install` and by PrinterBar's Install / Repair button.
# Usage: install.sh <foo2zjs> <rastertozjs> <ppd>
set -eu
[ $# -eq 3 ] || { echo "usage: $0 foo2zjs rastertozjs ppd" >&2; exit 2; }

PREFIX=/Library/Printers/HP-P1102
PPD_DIR=/Library/Printers/PPDs/Contents/Resources
QUEUE=HP_LaserJet_P1102
# No serial number, so the queue matches any P1102 and can be created unplugged.
URI='usb://Hewlett-Packard/HP%20LaserJet%20Professional%20P1102'

install -d -o root -g wheel -m 755 "$PREFIX/bin" "$PREFIX/filter" "$PPD_DIR"
install -o root -g wheel -m 755 "$1" "$PREFIX/bin/foo2zjs"
install -o root -g wheel -m 755 "$2" "$PREFIX/filter/rastertozjs"
install -o root -g wheel -m 644 "$3" "$PPD_DIR/HP-LaserJet-P1102.ppd"
lpadmin -p "$QUEUE" -E -v "$URI" -P "$PPD_DIR/HP-LaserJet-P1102.ppd" \
  -D 'HP LaserJet P1102' -o printer-is-shared=false
echo "Installed. Print to '$QUEUE' from any app."
