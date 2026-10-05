# HP LaserJet P1102 driver and PrinterBar for macOS. Run `make help` for targets.

PREFIX   := /Library/Printers/HP-P1102
PPD_DIR  := /Library/Printers/PPDs/Contents/Resources
PPD      := HP-LaserJet-P1102.ppd
QUEUE    := HP_LaserJet_P1102

ARCHS    := -arch arm64 -arch x86_64
CC       := clang
CFLAGS   := -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations $(ARCHS)
FOO2     := vendor/foo2zjs
FOO2SRC  := $(FOO2)/foo2zjs.c $(FOO2)/jbig.c $(FOO2)/jbig_ar.c
B        := build
APP      := $(B)/PrinterBar.app
SWIFTFLAGS := -c release --arch arm64 --arch x86_64 --package-path app

.PHONY: all help test analyze install uninstall print-test app app-test install-app screens perf perf-lifecycle bench clean

all: $(B)/foo2zjs $(B)/rastertozjs ## Build universal (arm64 + x86_64) binaries

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

$(FOO2)/foo2zjs.c:
	git submodule update --init

$(B)/foo2zjs: $(FOO2SRC)
	@mkdir -p $(B)
	$(CC) -O2 -w $(ARCHS) -o $@ $(FOO2SRC)

$(B)/zjsdecode: $(FOO2)/foo2zjs.c
	@mkdir -p $(B)
	$(CC) -O2 -w -o $@ $(FOO2)/zjsdecode.c $(FOO2)/jbig.c $(FOO2)/jbig_ar.c

$(B)/rastertozjs: driver/src/rastertozjs.c
	@mkdir -p $(B)
	$(CC) $(CFLAGS) -DFOO2ZJS='"$(PREFIX)/bin/foo2zjs"' -o $@ $< -lcups

# Same filter, but pointed at the foo2zjs in build/ so tests need no install.
$(B)/test/rastertozjs: driver/src/rastertozjs.c
	@mkdir -p $(B)/test
	$(CC) $(CFLAGS) -DFOO2ZJS='"$(CURDIR)/$(B)/foo2zjs"' -o $@ $< -lcups

test: $(B)/foo2zjs $(B)/zjsdecode $(B)/test/rastertozjs ## Run the print pipeline on test pages (no printer needed)
	driver/test/check.sh

analyze: ## Run the clang static analyzer on the filter
	$(CC) --analyze -Xclang -analyzer-werror -Wno-deprecated-declarations driver/src/rastertozjs.c -o /dev/null

install: all ## Install the driver and create the print queue (sudo)
	driver/install.sh $(B)/foo2zjs $(B)/rastertozjs driver/ppd/$(PPD)

uninstall: ## Remove the print queue and driver (sudo)
	-lpadmin -x $(QUEUE)
	rm -rf $(PREFIX)
	rm -f $(PPD_DIR)/$(PPD)

print-test: ## Print an A4 test page on the installed queue
	@mkdir -p $(B)
	swift tools/testpage.swift $(B)/testpage.pdf A4
	lp -d $(QUEUE) $(B)/testpage.pdf

app: all ## Build PrinterBar.app, the menu bar app (bundles the driver)
	swift build $(SWIFTFLAGS)
	rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources/driver
	cp "$$(swift build $(SWIFTFLAGS) --show-bin-path)/PrinterBar" $(APP)/Contents/MacOS/
	cp app/Info.plist $(APP)/Contents/
	cp $(B)/foo2zjs $(B)/rastertozjs driver/ppd/$(PPD) driver/install.sh $(APP)/Contents/Resources/driver/
	for s in A4 Letter Legal; do swift tools/testpage.swift $(APP)/Contents/Resources/testpage-$$s.pdf $$s > /dev/null; done
	codesign --force --sign - $(APP)

app-test: ## Run PrinterBar unit tests
	swift test --package-path app

install-app: app ## Copy PrinterBar.app to /Applications and open it
	rm -rf /Applications/PrinterBar.app
	cp -R $(APP) /Applications/
	open /Applications/PrinterBar.app

screens: app ## Render every PrinterBar screen to docs/screens
	$(APP)/Contents/MacOS/PrinterBar --render-screens $(CURDIR)/docs/screens

perf: app ## Measure PrinterBar: CPU, memory, CUPS requests (throwaway queue, ~4 min)
	tools/perf/perf.sh

perf-lifecycle: app ## Check cupsd can exit, popover memory, launch time (~4 min)
	tools/perf/lifecycle.sh

bench: ## Time the driver filter on a 10-page job and hash its output
	tools/perf/filter-bench.sh

clean: ## Remove build output
	rm -rf $(B) app/.build
