# HP LaserJet P1102 driver for macOS. Run `make help` for targets.

PREFIX   := /Library/Printers/HP-P1102
PPD_DIR  := /Library/Printers/PPDs/Contents/Resources
PPD      := HP-LaserJet-P1102.ppd
QUEUE    := HP_LaserJet_P1102
# No serial number, so the queue matches any P1102 and can be created unplugged.
URI      := usb://Hewlett-Packard/HP%20LaserJet%20Professional%20P1102

ARCHS    := -arch arm64 -arch x86_64
CC       := clang
CFLAGS   := -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations $(ARCHS)
FOO2     := vendor/foo2zjs
FOO2SRC  := $(FOO2)/foo2zjs.c $(FOO2)/jbig.c $(FOO2)/jbig_ar.c
B        := build

.PHONY: all help test analyze install uninstall print-test clean

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
	install -d -o root -g wheel -m 755 $(PREFIX)/bin $(PREFIX)/filter $(PPD_DIR)
	install -o root -g wheel -m 755 $(B)/foo2zjs $(PREFIX)/bin/foo2zjs
	install -o root -g wheel -m 755 $(B)/rastertozjs $(PREFIX)/filter/rastertozjs
	install -o root -g wheel -m 644 driver/ppd/$(PPD) $(PPD_DIR)/$(PPD)
	lpadmin -p $(QUEUE) -E -v '$(URI)' -P $(PPD_DIR)/$(PPD) \
		-D 'HP LaserJet P1102' -o printer-is-shared=false
	@echo "Installed. Print to '$(QUEUE)' from any app."

uninstall: ## Remove the print queue and driver (sudo)
	-lpadmin -x $(QUEUE)
	rm -rf $(PREFIX)
	rm -f $(PPD_DIR)/$(PPD)

print-test: ## Print an A4 test page on the installed queue
	@mkdir -p $(B)
	swift tools/testpage.swift $(B)/testpage.pdf A4
	lp -d $(QUEUE) $(B)/testpage.pdf

clean: ## Remove build output
	rm -rf $(B)
