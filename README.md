# HP LaserJet P1102 driver for macOS (Apple Silicon)

The P1102 only speaks ZjStream (`CMD:ZJS,PJL`). It has no PostScript or PCL,
so the Mac has to rasterise every page. This driver renders with macOS's own
Quartz rasteriser, so it needs no Ghostscript or Homebrew at print time.

```
app -> PDF -> cgpdftoraster -> rastertozjs -> foo2zjs -z2 -> usb backend
```

- `src/rastertozjs.c`: CUPS filter. Halftones 8-bit gray raster to 1-bit PBM
  and pipes it into foo2zjs. It maps page size, media type, density and toner save.
- `ppd/HP-LaserJet-P1102.ppd`: queue definition. Printable area is 96px in from
  each edge at 600 dpi.
- `vendor/foo2zjs`: upstream ZjStream encoder ([OpenPrinting/foo2zjs](https://github.com/OpenPrinting/foo2zjs)), as a submodule.
- `tools/testpage.swift`: generates the test page. `tools/pbm2png.py` previews filter output.

## Build

```sh
git submodule update --init
clang -O2 -o foo2zjs vendor/foo2zjs/{foo2zjs,jbig,jbig_ar}.c
clang -O2 -Wno-deprecated-declarations -o rastertozjs src/rastertozjs.c -lcups
```

## Status

- Verified: a test page encoded by `rastertozjs` + `foo2zjs` and sent through
  `/usr/libexec/cups/backend/usb` prints correctly.
- Not done yet: installing to `/Library/Printers/HP-P1102` (needs sudo) and
  creating the CUPS queue. The PPD's `cupsFilter2` output type still needs
  checking against a real queue.
