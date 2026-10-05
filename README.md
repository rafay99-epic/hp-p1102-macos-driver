# HP LaserJet P1102 for macOS

[![CI](https://github.com/rafay99-epic/hp-p1102-macos-driver/actions/workflows/ci.yml/badge.svg)](https://github.com/rafay99-epic/hp-p1102-macos-driver/actions/workflows/ci.yml)

A working print driver for the HP LaserJet Professional P1102 on current macOS,
Apple Silicon and Intel, plus **PrinterBar**, a menu bar app that opens on its
own when you switch the printer on.

HP never shipped an Apple Silicon driver for the P1102, and macOS doesn't
include one. With this installed, the printer works from every app's print
dialog (<kbd>⌘P</kbd>) like any other printer.

<p align="center">
  <img src="docs/screens/2-printing.png" width="300" alt="PrinterBar while printing">
  &nbsp;
  <img src="docs/testpage.png" width="250" alt="Test page rendered by the driver">
</p>

## Requirements

| | |
|---|---|
| Mac | Apple Silicon or Intel. Every build is universal. |
| macOS | Driver: tested on macOS 27; earlier versions should work but are untested. PrinterBar: macOS 14 or later. |
| To build | Xcode Command Line Tools (`xcode-select --install`) and git. PrinterBar also needs Xcode for Swift. |
| Printer | HP LaserJet Professional P1102, connected by USB |

There are no prebuilt downloads. The apps aren't signed with an Apple Developer
ID, so building them yourself is the clean way to install them.

## Install

```sh
git clone --recursive https://github.com/rafay99-epic/hp-p1102-macos-driver.git
cd hp-p1102-macos-driver
sudo make install      # driver + print queue
make install-app       # PrinterBar, copied to /Applications and opened
```

`sudo make install` copies the driver to `/Library/Printers/HP-P1102`, adds the
PPD and creates a print queue called **HP_LaserJet_P1102**. The printer can be
unplugged while you do this. PrinterBar can also install the driver for you:
its **Install Driver** button asks for your password and runs the same script.

Then switch the printer on and print a test page from PrinterBar, or with
`make print-test`.

## Printing

Print from anything with <kbd>⌘P</kbd> and choose **HP LaserJet P1102**: PDFs
in Preview, Word, Excel and PowerPoint, Pages, Numbers, Keynote, or web pages
from a browser. Color prints in grayscale.

| Option in the print dialog | Choices |
|---|---|
| Paper Size | A4 (default), US Letter, US Legal, Executive, A5, A6, JIS B5, envelopes #10, DL, C5, Monarch |
| Paper Type | Plain, Light, Heavy, Recycled, Rough, Labels, Envelope, Transparency |
| Print Density | 1 (lightest) to 5 (darkest) |
| Toner Save | Off / On |

The printer prints at 600 dpi and leaves a 4 mm (0.16 in) unprintable border.
It has no duplexer; PrinterBar walks you through two-sided printing by hand.

## PrinterBar

The menu bar icon appears when the printer is switched on and the app quits
when it's switched off. Nothing runs in the background in between: launchd
starts the app when the printer shows up on USB.

<p align="center">
  <img src="docs/screens/1-ready.png" width="270" alt="Ready">
  <img src="docs/screens/6-queue.png" width="270" alt="Queue">
  <img src="docs/screens/7-settings.png" width="270" alt="Settings">
</p>

- **Status and queue.** What's printing, page by page, what's waiting, and what printed today. Cancel, reprint, or move a job to the front.
- **Print files.** Drop files on the icon or use **Print File…** (<kbd>⌘O</kbd>). PDFs, images and text print directly. Word, PowerPoint, Excel and iWork files are handed to their own app, which prints them to the P1102.
- **Two-sided printing.** Prints the fronts, tells you how to reload the stack, then prints the backs. A one-time calibration sheet fixes the order for your setup. Hold <kbd>⌥</kbd> while dropping a PDF to print it two-sided.
- **Defaults.** Paper, paper type, density and toner save, saved on the print queue, so every app's <kbd>⌘P</kbd> uses them too.
- **Problems.** Out of paper, jams, or a job that stops making progress show up in red, with what to do about each.
- **Driver check.** Notices a missing driver or a second queue macOS added for the same printer, and repairs both.

<p align="center">
  <img src="docs/screens/9-two-sided.png" width="270" alt="Two-sided wizard">
  <img src="docs/screens/4-attention.png" width="270" alt="Needs attention">
  <img src="docs/screens/3-print-file.png" width="270" alt="Print file">
</p>

Menu bar icons, from left to right: ready, printing, paused, needs attention,
waiting for the printer.

<p align="center">
  <img src="docs/screens/icon-ready.png" width="36" alt="Ready">
  <img src="docs/screens/icon-printing.png" width="36" alt="Printing">
  <img src="docs/screens/icon-paused.png" width="36" alt="Paused">
  <img src="docs/screens/icon-attention.png" width="36" alt="Needs attention">
  <img src="docs/screens/icon-held.png" width="36" alt="Waiting for printer">
</p>

**Where's the icon?** On a MacBook with a notch, a full menu bar hides new
icons behind it. Hold <kbd>⌘</kbd> and drag other icons off the bar, or use a
menu bar manager.

To stop PrinterBar opening automatically, turn off **Open when the printer
connects** in its settings.

## Commands

| | |
|---|---|
| `make` | Build the driver (universal binaries in `build/`) |
| `make test` | Run A4, Letter and Legal test pages through the real macOS print pipeline and check the output. No printer needed. |
| `make analyze` | Run the clang static analyzer on the filter |
| `sudo make install` | Install the driver and create the queue |
| `sudo make uninstall` | Remove the queue and every driver file |
| `make print-test` | Print a test page on the installed queue |
| `make app` | Build `build/PrinterBar.app` (it bundles the driver for Install / Repair) |
| `make install-app` | Copy PrinterBar to `/Applications` and open it |
| `make app-test` | Run PrinterBar's unit tests |
| `make screens` | Render every PrinterBar screen to `docs/screens` |
| `make perf` | Measure PrinterBar's CPU, memory and CUPS traffic (see [Performance](#performance)) |
| `make perf-lifecycle` | Check that cupsd can sleep, popover memory, and launch time |
| `make bench` | Time the driver filter and hash its output |
| `make help` | List all targets |

## How it works

The P1102 is a host-based printer. It reports `CMD:ZJS,PJL`: it only accepts
finished bitmaps in HP's ZjStream format, with no PostScript or PCL. So the Mac
does all the rendering:

```
any app ⌘P → CUPS queue → cgpdftoraster → rastertozjs → foo2zjs → USB → P1102
                          (Apple, Quartz)  (this repo)   (vendored)
```

macOS renders the page with its own Quartz engine. `rastertozjs`, a small CUPS
filter written in C, turns it into black and white dots, and
[foo2zjs](https://github.com/OpenPrinting/foo2zjs) encodes those as ZjStream.
Nothing else is needed at print time: no Ghostscript, no Homebrew.

PrinterBar never touches the driver directly. It only talks to the CUPS queue,
so the driver works without the app, and the app shows "Driver missing"
without the driver.

## Performance

PrinterBar sits in the menu bar for as long as the printer is on, so it has to
cost close to nothing. It doesn't poll: CUPS on macOS posts a system
notification (`com.apple.jobChange`, `com.apple.printerHistoryChange`,
`com.apple.printerListChange`) for every job and queue change, and the app
sleeps until one arrives. The only timer is a 3 second check while a page is
printing, because page progress posts nothing. Everything it shows comes from
one or two small IPP requests, never a spawned command line tool.

Measured with `make perf` over 60 seconds per scenario, with 500 finished jobs
in the queue history, before and after the performance pass:

| | idle | jobs waiting | popover open |
|---|---|---|---|
| CUPS requests | 24 → 4 | 72 → 4 | 21 → 5 |
| Processes spawned | 8 → 0 | 24 → 0 | 7 → 0 |
| CPU instructions (millions) | 5,083 → 1,503 | 7,414 → 1,256 | 4,648 → 1,757 |
| Memory footprint | 21 → 13 MB | 16 → 13 MB | 21 → 20 MB |

The driver filter uses about 42 ms of CPU and 1.4 MB of memory per page; the
printer takes about 3.3 s to print one, so the filter is idle 99% of a job.

### Measuring it yourself

The tools work for a person or a coding agent: run them, read the table, change
something, run them again. None of them prints anything or touches your real
queue: they create a stopped throwaway queue, `PrinterBar_Perf`, and delete it
when they finish.

| Tool | What it answers |
|---|---|
| `make perf` (`tools/perf/perf.sh [seconds] [history jobs]`) | Per scenario (idle, jobs waiting, popover open): the app's CPU, CPU of processes it spawned, cupsd CPU, instructions retired, context switches, memory footprint, threads, launch time, IPP requests, spawns, refreshes and view updates. `APP=path/to/PrinterBar` compares another build. |
| `make perf-lifecycle` (`tools/perf/lifecycle.sh`) | Does cupsd get to exit while the app idles? Does memory grow over 25 popover open/close cycles? Median launch time over 5 runs. Needs Accessibility access for the terminal, to click the menu bar item. |
| `make bench` (`tools/perf/filter-bench.sh [runs]`) | CPU time of the driver filter on a 10-page A4 job, plus SHA-256 hashes of its output, so a faster filter can be checked for byte-identical results. |
| `tools/perf/ipp/*.test` | `ipptool` scripts for the CUPS questions behind the design, e.g. `ipptool -t ipp://localhost/printers/HP_LaserJet_P1102 tools/perf/ipp/jobs-all.test` vs `jobs-lean.test` shows why the app asks for 7 job attributes instead of all of them (about 130 ms vs 17 ms with a 500-job history). `subscribe.test` shows CUPS on macOS rejects IPP event subscriptions, which is why the app uses system notifications. |

Setting `PRINTERBAR_PERF=1` turns on the app's internal counters, printed to
stderr when it receives SIGTERM; `PRINTERBAR_QUEUE=name` points it at another
queue. Both are off in normal use and cost nothing.

Wall-clock numbers (launch time, CPU milliseconds) swing with whatever else the
Mac is doing. Request, spawn and refresh counts, instructions retired and
context switches don't, so compare those.

## Troubleshooting

**The green light blinks and nothing prints.** A job stopped partway and the
printer is still waiting for the rest of it. Turn the printer off and on, then
choose **Try Again** in PrinterBar.

**There are two P1102 printers in the print dialog.** macOS sometimes adds its
own queue when you plug the printer in. PrinterBar's driver check removes it,
or remove it in System Settings → Printers & Scanners. The one that works is
**HP_LaserJet_P1102**.

**A job fails.** Turn on CUPS debug logging, print again, and read the log:

```sh
cupsctl --debug-logging
make print-test
grep -a rastertozjs /var/log/cups/error_log | tail -20
cupsctl --no-debug-logging
```

**The printer isn't found on USB.** Some units ship with HP Smart Install
turned on, which makes the printer show up as a CD drive instead. It has to be
turned off once from a Windows PC with HP's tool.

## Repository layout

```
driver/src/rastertozjs.c       CUPS filter: gray raster → black/white → foo2zjs
driver/ppd/                    PPD: paper sizes, options, printable area
driver/install.sh              installs the driver; used by make and PrinterBar
driver/test/check.sh           print pipeline tests (`make test`, CI)
app/Sources/PrinterBarKit/     CUPS access, queue settings, two-sided logic (tested)
app/Sources/PrinterBar/        menu bar app: USB watcher, launch agent, screens
vendor/foo2zjs/                ZjStream encoder (git submodule, unmodified)
tools/                         test page generator, PBM preview tool
tools/perf/                    performance harness, lifecycle checks, filter benchmark
```

CI builds everything for both architectures, runs the analyzer and both test
suites, installs the driver for real, tests PrinterBar against the installed
queue, renders every screen, and uninstalls. Dependabot opens a PR each month
if foo2zjs upstream or the action versions change.

## Licence

foo2zjs is © Rick Richardson and contributors, GPL-2.0-or-later
([OpenPrinting/foo2zjs](https://github.com/OpenPrinting/foo2zjs)).
