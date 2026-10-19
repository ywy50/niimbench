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
| [../tools/panel-layout.test.js](../tools/panel-layout.test.js) | Checks how the editor's panels make room for a moved or resized one, under node (`make panel-test`) |
| [../tools/canvas-test.sh](../tools/canvas-test.sh), [../tools/canvas.test.js](../tools/canvas.test.js) | Load the page in a headless browser and check what it drew and what its self-check reported (`make canvas-test`) |
| [../tools/trace-test.sh](../tools/trace-test.sh), [../tools/trace-test.js](../tools/trace-test.js) | Load the page once and check the trace both sides wrote (`make trace-test`) |
| [../tools/trace.sh](../tools/trace.sh) | Clears the trace, runs a command, prints what it recorded |
| [../tools/with-server.sh](../tools/with-server.sh) | Runs one command against a throwaway server, then stops it: how checks and agents get a server |
| [../tools/drive.js](../tools/drive.js) | Drives the page in a headless browser with real input and screenshots (`make drive`) |
| [../tools/screens.drive.js](../tools/screens.drive.js) | Resizes the page from a phone to a wide desktop, and with the text panel dragged narrow, and fails when anything is cut off or overlaps (`make screens-test`) |
| [../tools/stray-test.sh](../tools/stray-test.sh) | Checks no server outlives its launcher, even one killed with SIGKILL (`make stray-test`) |
| [../tools/fetch-labels.py](../tools/fetch-labels.py) | Refreshes the label catalogue from the vendor cloud (`make labels`); standard library only, run through `uv` |

`make test` runs every check in this table that has a target, then `zig build test`. The browser checks skip themselves, saying so, when no Chromium-family browser is found; `BROWSER=` names one.

## Boot list

`src/default.patch.yml` is compiled into the binary. `cordis.patch.yml` at the root is the same list and, when you run from this directory, replaces the embedded copy. Edit both, and keep `inject` identical to the `Plugin.inject` slice in `src/plugins.zig`. A mismatch is `error.InjectMismatch`.

## Process lifetime

`main` builds a context on the general-purpose allocator, loads the patch, and either serves HTTP or prints one image. `ctx.deinit` disposes fibers from last to first.

Serving runs one at a time. `runServe` takes an exclusive `flock` on `.niimbench.lock` in the working directory before the listener exists, so a second start never binds a second port. A second start that may open a browser, which is the default, opens the running server's page from the address in `.niimbench.token` and exits 0: that is what a second click on a launcher means. A second start with `--no-open` prints the pid that holds the lock and exits 1, as a script expects. The kernel releases the lock when the process ends however it ends, so there is no stale lock to clear. Stray servers are worth preventing: each has its own port and its own session token, and a page left open on an old one looks like the page just built.

The HTTP listener and the bytes sent to the printer are process effects. They are not Cordis effects. Stopping the process closes the listener. A print that has already reached `start_print` finishes with `end_print`.

## Throwaway servers

A check or an agent never starts a server with `&`: a server started that way outlives whoever started it. `tools/with-server.sh COMMAND` starts one in a directory of its own, booted from [../tools/harness.patch.yml](../tools/harness.patch.yml) so no printer is reachable, runs the command with `NIIMBENCH_URL`, `NIIMBENCH_PID` and `NIIMBENCH_DIR` in its environment, and stops the server when the command ends. `make trace-test`, `make canvas-test` and `make drive` all run under it.

The server cannot outlive the script. `with-server.sh` passes its own pid as `--parent`, and the server asks the kernel (`PR_SET_PDEATHSIG`) to send it `SIGKILL` when its parent exits, however the parent exits: a launcher killed outright, which never runs its cleanup, still takes its server with it. A `--parent` that is not the server's parent is refused at startup, before the lock is taken. `make stray-test` checks a finished command, a launcher killed with `SIGKILL`, and a wrong `--parent`.

`make drive` loads the page in a headless browser and drives it with real mouse input. `STEPS=` names a steps file, whose API is at the top of [../tools/drive.js](../tools/drive.js); without one it opens the page, screenshots it into `zig-out/drive/`, and fails if the page threw. The browser runs under `setpriv --pdeathsig KILL`, so it dies with the driver.

## CI and releases

[../.github/workflows/ci.yml](../.github/workflows/ci.yml) runs `zig fmt --check` and `make test` on every push to `main` and every pull request, on Ubuntu with the runner's own Chrome, so the browser checks run there rather than skip. A `macos` job runs `zig build test` and serves the page once on an arm64 and an Intel Mac, where the CoreBluetooth checks run instead of skipping. [../.github/workflows/release.yml](../.github/workflows/release.yml) publishes a `vX.Y.Z` tag. The version is written once, in `build.zig.zon`, which `build.zig` passes to the code as `build_options.version` and `niimbench --version` prints. Cutting a release is [cookbook/releasing.md](cookbook/releasing.md).

## Docs map

The index of every page is [README.md](README.md), and the rules for writing them are [AGENTS.md](AGENTS.md).
