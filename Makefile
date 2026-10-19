# niimbench. `make` serves the editor and opens it.
ZIG ?= zig

PORT ?=
MODEL ?= b21
CONN ?= usb
DENSITY ?= 5
ROTATE ?= 0
ARGS ?=
STEPS ?=
SIZE ?= 1600x1000
DRIVE_OUT ?= zig-out/drive

.DEFAULT_GOAL := run
.PHONY: help test build run serve trace print labels lint protocol-test view-test box-test panel-test canvas-test trace-test stray-test drive screens-test

help:
	@printf '%s\n' \
		'TARGETS' \
		'  make                 serve the editor and open it' \
		'  make serve           serve on 127.0.0.1 without opening a browser' \
		'  make trace           print the log of the server running in this checkout' \
		'  make test            every check below, then zig build test' \
		'  make build           zig build' \
		'  make print           print a binary P5 PGM (see PRINT)' \
		'  make labels          refresh the label catalogue from the vendor cloud' \
		'  make lint            lint the editor script, check references and doc links' \
		'  make protocol-test   check the page records every boot step, with node' \
		'  make view-test       check the editor preview geometry with node' \
		'  make box-test        check the field box geometry with node' \
		'  make panel-test      check the editor'\''s panel layout with node' \
		'  make canvas-test     check the drawn canvas in headless Chrome' \
		'  make trace-test      run the page once and check the trace it wrote' \
		'  make stray-test      check no server outlives whoever started it' \
		'  make screens-test    check the page fits phone to desktop sizes, in headless Chrome' \
		'  make drive           drive the page in a headless browser (see DRIVE)' \
		'' \
		'PRINT' \
		'  IMAGE=label.pgm      binary P5 file to print (required)' \
		'  ADDR=/dev/ttyACM0    tty path or Bluetooth address (required)' \
		'  MODEL=$(MODEL)            printer model' \
		'  CONN=$(CONN)             usb or bluetooth' \
		'  DENSITY=$(DENSITY)            print density' \
		'  ROTATE=$(ROTATE)             page turn in degrees' \
		'' \
		'DRIVE' \
		'  STEPS=steps.js       a steps file, see tools/drive.js (default: one screenshot)' \
		'  SIZE=$(SIZE)       window size' \
		'  DRIVE_OUT=dir        where screenshots go (default: zig-out/drive)' \
		'' \
		'VARIABLES' \
		'  PORT=8080            listen port for run and serve (default: ephemeral)' \
		'  ARGS="..."           extra arguments after the built-in ones' \
		'  ZIG=zig              zig binary'

run:
	$(ZIG) build run -- $(if $(PORT),--port $(PORT),) $(ARGS)

serve:
	$(ZIG) build run -- --no-open $(if $(PORT),--port $(PORT),) $(ARGS)

trace:
	@test -r .niimbench.token || { echo "no .niimbench.token here: start the server with make or make serve"; exit 1; }
	@curl -fsS "$$(sed 's|/?token=|/api/trace?token=|' .niimbench.token)"

build:
	$(ZIG) build $(ARGS)

test: lint protocol-test view-test box-test panel-test stray-test trace-test canvas-test drive screens-test
	$(ZIG) build test $(ARGS)

# The page script runs only in a browser, so nothing else would notice a name
# it uses but never declares until someone clicked the control. The reference
# check keeps other projects' names to the README's one credit line, and the
# link check keeps every relative doc link pointing at something.
lint:
	@tools/lint-page.sh
	@tools/check-references.sh
	@node tools/check-doc-links.js

# The editor's geometry is JavaScript, so it is checked with node. Neither needs
# a browser: both lift the functions out of the page and run them.
view-test:
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make view-test"; exit 1; }
	node tools/view-geometry.test.js

box-test:
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make box-test"; exit 1; }
	node tools/box-geometry.test.js

panel-test:
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make panel-test"; exit 1; }
	node tools/panel-layout.test.js

# The drawn canvas, in a real browser. The geometry checks assert the page's
# maths; this asserts the pixels a person sees, which is where a box off the
# canvas or beside its text actually shows up. Skipped, loudly, when Chrome is
# not installed: a silently skipped check is worse than none.
# The skip and the run are one shell line: each recipe line is a shell of its
# own, so an `exit 0` on a line of its own skipped nothing.
# Any Chromium-family browser. The check only needs `--headless=new`,
# `--dump-dom` and `--virtual-time-budget`, which all of them accept, so this is
# not tied to one vendor or one installed version.
# Stable Google Chrome comes first when it is there: a CI runner also carries a
# Chromium development snapshot, whose --dump-dom never exited.
BROWSER ?= $(shell for name in google-chrome-stable google-chrome chromium chromium-browser chrome microsoft-edge; do \
	path=$$(command -v $$name 2>/dev/null); if [ -n "$$path" ]; then echo $$path; exit 0; fi; done; \
	ls -d $$HOME/.cache/ms-playwright/chromium*/chrome-linux64/chrome 2>/dev/null | head -1)

# The harness. Start here when the editor misbehaves: it prints the trace both
# sides wrote and fails if a step went unrecorded, so the trace cannot drift
# behind the page. Adding a step to the boot without tracing it fails here, and
# the message says where to add it.
trace-test: build
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make trace-test"; exit 1; }
	@if [ -z "$(BROWSER)" ]; then echo "trace-test: no Chromium-family browser found, skipping (set BROWSER= to run it)"; \
	else tools/trace-test.sh "$(BROWSER)"; fi

canvas-test: build
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make canvas-test"; exit 1; }
	@if [ -z "$(BROWSER)" ]; then echo "canvas-test: no Chromium-family browser found, skipping (set BROWSER= to run it)"; \
	else tools/canvas-test.sh "$(BROWSER)"; fi

# A server started by hand with `&` outlives whoever started it. These are the
# two ways a check or an agent gets one instead: tools/with-server.sh starts a
# throwaway server that the kernel kills when the script ends, however it ends,
# and stray-test proves that holds even for a launcher killed with SIGKILL.
stray-test: build
	@tools/stray-test.sh

# The page with real input, for a look the self-check does not cover. Without
# STEPS it opens the page, screenshots it and fails if the page threw, which is
# also what keeps the driver itself working.
drive: build
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make drive"; exit 1; }
	@if [ -z "$(BROWSER)" ]; then echo "drive: no Chromium-family browser found, skipping (set BROWSER= to run it)"; \
	else BROWSER="$(BROWSER)" SIZE="$(SIZE)" DRIVE_OUT="$(DRIVE_OUT)" tools/with-server.sh node tools/drive.js $(STEPS); fi

print:
	@test -n "$(IMAGE)" || { echo "set IMAGE= to a binary P5 file"; exit 1; }
	@test -n "$(ADDR)" || { echo "set ADDR= to a tty path or a Bluetooth address"; exit 1; }
	$(ZIG) build run -- print --image "$(IMAGE)" --addr "$(ADDR)" --model "$(MODEL)" --conn "$(CONN)" --density "$(DENSITY)" --rotate "$(ROTATE)" $(ARGS)

# Refresh the label catalogue and copy it next to the code that embeds it.
# The vendor's endpoint needs no key. `docs/labels/README.md` is regenerated by
# hand from the same JSON when the catalogue changes.
labels:
	uv run tools/fetch-labels.py > docs/labels/catalogue.json
	cp docs/labels/catalogue.json src/catalogue.json

# The trace protocol in the page's own source: every declared step is recorded
# somewhere, and every boot phase records one. No browser and no server.
protocol-test:
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make protocol-test"; exit 1; }
	node tools/trace-protocol.test.js

screens-test: build
	@command -v node >/dev/null 2>&1 || { echo "node is needed for make screens-test"; exit 1; }
	@if [ -z "$(BROWSER)" ]; then echo "screens-test: no Chromium-family browser found, skipping (set BROWSER= to run it)"; \
	else BROWSER="$(BROWSER)" DRIVE_OUT="$(DRIVE_OUT)" tools/with-server.sh node tools/drive.js tools/screens.drive.js; fi
