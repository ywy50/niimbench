# Development

Zig 0.17. Node and a Chromium-family browser are needed for the checks `make test` runs beyond `zig build test`. Run these from the repository root.

Run every check:

```bash
make test
```

Serve the editor on a fixed port without opening a browser:

```bash
make serve PORT=8080
```

Print a binary PGM over USB:

```bash
make print IMAGE=label.pgm ADDR=/dev/ttyACM0
```

The [Makefile](../Makefile) calls `zig build`. `make help` lists the targets and the variables `PORT`, `IMAGE`, `ADDR`, `MODEL`, `CONN`, `DENSITY`, `ROTATE`, and `ARGS`. `ZIG` selects the compiler.

`label.pgm` is a binary P5 file: `P5`, width, height, maxval `255`, then one byte per pixel. `0` is black and `255` is white.

`tools/` holds the scripts that are not part of the build:

| Script | What it is |
|---|---|
| [../tools/lint-page.sh](../tools/lint-page.sh) | Lints the editor's script for undefined and unused names with a pinned ESLint (`make lint`) |
| [../tools/check-references.sh](../tools/check-references.sh) | Fails when another project is named outside the README's credit line (`make lint`) |
| [../tools/check-doc-links.js](../tools/check-doc-links.js) | Fails when a relative markdown link points at a missing file or heading (`make lint`) |
| [../tools/trace-protocol.test.js](../tools/trace-protocol.test.js) | Checks every boot step the page declares is recorded, without a browser (`make protocol-test`) |
| [../tools/view-geometry.test.js](../tools/view-geometry.test.js) | Checks the editor's preview geometry under node (`make view-test`) |
| [../tools/box-geometry.test.js](../tools/box-geometry.test.js) | Checks the field box size, font, angle, anchor and drag under node (`make box-test`) |
| [../tools/canvas-test.sh](../tools/canvas-test.sh), [../tools/canvas.test.js](../tools/canvas.test.js) | Load the page in a headless browser and check what it drew and what its self-check reported (`make canvas-test`) |
| [../tools/trace-test.sh](../tools/trace-test.sh), [../tools/trace-test.js](../tools/trace-test.js) | Load the page once and check the trace both sides wrote (`make trace-test`) |
| [../tools/trace.sh](../tools/trace.sh) | Clears the trace, runs a command, prints what it recorded |
| [../tools/fetch-labels.py](../tools/fetch-labels.py) | Refreshes the label catalogue from the vendor cloud (`make labels`); standard library only, run through `uv` |

`make test` runs every check in this table that has a target, then `zig build test`. The browser checks skip themselves, saying so, when no Chromium-family browser is found; `BROWSER=` names one.

## Boot list

`src/default.patch.yml` is compiled into the binary. `cordis.patch.yml` at the root is the same list and, when you run from this directory, replaces the embedded copy. Edit both, and keep `inject` identical to the `Plugin.inject` slice in `src/plugins.zig`. A mismatch is `error.InjectMismatch`.

## Process lifetime

`main` builds a context on the general-purpose allocator, loads the patch, and either serves HTTP or prints one image. `ctx.deinit` disposes fibers from last to first.

Serving runs one at a time. `runServe` takes an exclusive `flock` on `.niimbench.lock` in the working directory before the listener exists, so a second start prints the pid that holds it and exits with `error.AlreadyServing` rather than binding a second port. The kernel releases the lock when the process ends however it ends, so there is no stale lock to clear. Stray servers are worth preventing: each has its own port and its own session token, and a page left open on an old one looks like the page just built.

The HTTP listener and the bytes sent to the printer are process effects. They are not Cordis effects. Stopping the process closes the listener. A print that has already reached `start_print` finishes with `end_print`.

## Docs map

The index of every page is [README.md](README.md), and the rules for writing them are [AGENTS.md](AGENTS.md).
