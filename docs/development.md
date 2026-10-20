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

The [Makefile](../Makefile) calls `zig build`. `make help` lists the targets and the variables `PORT`, `IMAGE`, `ADDR`, `MODEL`, `CONN`, `DENSITY`, `ROTATE`, `STEPS`, `SIZE`, `DRIVE_OUT`, `ARGS`, `ZIG`, which selects the compiler, and `BROWSER`.

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
| [../tools/linux-dist.sh](../tools/linux-dist.sh) | Builds one Linux release: the static binary, its tarball, and the `.deb` and `.rpm` |
| [../tools/linux-package-check.sh](../tools/linux-package-check.sh) | Installs a `.deb` or `.rpm` in a clean container and checks what it installed and that it starts |
| [../tools/get-nfpm.sh](../tools/get-nfpm.sh) | Puts the pinned, checksum-checked nfpm that makes the packages in a folder |
| [../tools/aur.sh](../tools/aur.sh) | Writes the AUR package's `PKGBUILD` and `.SRCINFO` for a release, from its tarballs' checksums |
| [../tools/aur-check.sh](../tools/aur-check.sh) | Builds, installs and lints the AUR package in a clean archlinux container, and checks it starts |
| [../tools/aur-push.sh](../tools/aur-push.sh) | Publishes the AUR package, when an AUR key is given |
| [../tools/macos-app.sh](../tools/macos-app.sh) | Builds `niimbench.app` and its zip on a Mac (`make macos-app`) |
| [../tools/macos-app-check.sh](../tools/macos-app-check.sh) | Starts `niimbench.app` as Finder does and checks it serves, reopens and quits (`make macos-app-check`) |

`make test` runs every check in this table that has a target, then `zig build test`. The browser checks skip themselves, saying so, when no Chromium-family browser is found; `BROWSER=` names one.

## Boot list

`src/default.patch.yml` is compiled into the binary. `cordis.patch.yml` at the root is the same list and, when you run from this directory, replaces the embedded copy. Edit both, and keep `inject` identical to the `Plugin.inject` slice in `src/plugins.zig`. A mismatch is `error.InjectMismatch`.

## Process lifetime

`main` builds a context on the general-purpose allocator, loads the patch, and either serves HTTP or prints one image. `ctx.deinit` disposes fibers from last to first. A server stops when the page's **Quit** posts `/api/quit`, or when no request has arrived for `--idle-minutes`, 30 by default and 0 for never; `serve` wakes once a minute to check, returns, and the process prints which of the two it was.

`--app` serves from a per-user folder instead of the working directory, for a start from a launcher, which has no folder of its own to give: Finder starts an app in `/`, which no one may write to, and a desktop menu starts it in the home folder. The folder is `~/Library/Application Support/niimbench` on macOS, and `$XDG_STATE_HOME/niimbench` elsewhere, `~/.local/state/niimbench` when that is unset or not absolute. Everything below that says working directory means that folder then. An argument that starts with `-psn_`, a process serial number macOS may hand an app it starts, is ignored.

Serving runs one at a time. `runServe` takes an exclusive `flock` on `.niimbench.lock` in the working directory before the listener exists, so a second start never binds a second port. A second start that may open a browser, which is the default, opens the running server's page from the address in `.niimbench.token` and exits 0: that is what a second click on a launcher means. A second start with `--no-open`, or one that finds no `.niimbench.token` to read, prints the pid that holds the lock and exits 1, as a script expects. The kernel releases the lock when the process ends however it ends, so there is no stale lock to clear. Stray servers are worth preventing: each has its own port and its own session token, and a page left open on an old one looks like the page just built.

The HTTP listener and the bytes sent to the printer are process effects. They are not Cordis effects. Stopping the process closes the listener. A print that has already reached `start_print` finishes with `end_print`.

## Throwaway servers

A check or an agent never starts a server with `&`: a server started that way outlives whoever started it. `tools/with-server.sh COMMAND` starts one in a directory of its own, booted from [../tools/harness.patch.yml](../tools/harness.patch.yml) so no printer is reachable, runs the command with `NIIMBENCH_URL`, `NIIMBENCH_PID` and `NIIMBENCH_DIR` in its environment, and stops the server when the command ends. `make trace-test`, `make canvas-test`, `make screens-test`, `make drive` and the macOS CI job all run under it.

The server cannot outlive the script. `with-server.sh` passes its own pid as `--parent`, and on Linux the server asks the kernel (`PR_SET_PDEATHSIG`) to send it `SIGKILL` when its parent exits, however the parent exits; on macOS, which has no such call, it checks for its parent every 100 ms and exits when it is gone: a launcher killed outright, which never runs its cleanup, still takes its server with it. A `--parent` that is not the server's parent is refused at startup, before the lock is taken. `make stray-test` checks a finished command, a launcher killed with `SIGKILL`, and a wrong `--parent`.

`make drive` loads the page in a headless browser and drives it with real mouse input. `STEPS=` names a steps file, whose API is at the top of [../tools/drive.js](../tools/drive.js); without one it opens the page, screenshots it into `zig-out/drive/`, and fails if the page threw. When `setpriv` is installed, the browser runs under `setpriv --pdeathsig KILL`, so it dies with the driver.

## Linux packages

[../tools/linux-dist.sh](../tools/linux-dist.sh) builds one Linux release into `zig-out/dist`, or the folder it is given: it builds the static `ReleaseSafe` binary for `x86_64-linux` or `aarch64-linux`, fails if the binary is dynamic or, where it can run, reports another version than `build.zig.zon`, stages the tarball's files, and writes `niimbench-TARGET.tar.gz`, `.deb` and `.rpm`, each with its `.sha256`. The packages are made by [nfpm](https://nfpm.goreleaser.com) from [../packaging/linux/nfpm.yaml](../packaging/linux/nfpm.yaml), run in the staged folder, so a package holds exactly what the tarball does. Without nfpm on `PATH` the tarball is still built. Put the pinned nfpm in a folder, then build:

```sh
tools/get-nfpm.sh ~/.local/bin
tools/linux-dist.sh x86_64-linux
```

The packages install the binary in `/usr/bin`, [../packaging/linux/niimbench.desktop](../packaging/linux/niimbench.desktop) in `/usr/share/applications`, the icon at `scalable` and `512x512` under `/usr/share/icons/hicolor`, the README and changelog under `/usr/share/doc/niimbench`, and the licences under `/usr/share/licenses/niimbench`. The menu entry runs `niimbench --app`. nfpm's `doc` and `license` file types are RPM's and are left out of a `.deb` altogether, so every file is a plain one.

[../tools/linux-package-check.sh](../tools/linux-package-check.sh) installs a package in a clean container with docker, as a person would with `apt` or `dnf`, checks the version, the menu entry, the icons and the licences, then, as a user of its own, starts `niimbench --app` and checks it serves from `~/.local/state/niimbench`, quits and cleans up. Nothing is installed on the machine that runs it:

```sh
tools/linux-package-check.sh zig-out/dist/niimbench-x86_64-linux.deb debian:stable-slim
tools/linux-package-check.sh zig-out/dist/niimbench-x86_64-linux.rpm fedora:42
```

## The AUR package

The AUR package is `niimbench-bin`: the release's own static binary, as published and attested, with the menu entry and icons from its tarball. [../packaging/aur/PKGBUILD.in](../packaging/aur/PKGBUILD.in) is its template. [../tools/aur.sh](../tools/aur.sh) fills in the version and each architecture's sha256, read from the `.sha256` files published beside the tarballs, and has makepkg write the `.SRCINFO`, here on Arch or in an archlinux container. A check points it at tarballs on disk instead of a release:

```sh
tools/linux-dist.sh x86_64-linux /tmp/dist
tools/linux-dist.sh aarch64-linux /tmp/dist
tools/aur.sh 0.7.0 /tmp/aur file:///tmp/dist
tools/aur-check.sh /tmp/aur file:///tmp/dist
```

[../tools/aur-check.sh](../tools/aur-check.sh) builds the package with makepkg and installs it with pacman in a clean archlinux container, lints the `PKGBUILD` and the package with namcap, and starts it as the menu entry does. namcap's findings fail it, except four it expects: a `-bin` package names `x86_64` in its sources, and the binary is the attested release build, so it is left unstripped, and static, so it has no dynamic loader for RELRO or PIE to harden. The AUR wants `hicolor-icon-theme` as a dependency for the icons. Publishing is [cookbook/releasing.md](cookbook/releasing.md#the-aur-package).

## The Mac app

`make macos-app` runs [../tools/macos-app.sh](../tools/macos-app.sh) on a Mac and leaves `niimbench.app`, `niimbench-macos.zip` and its `.sha256` in `zig-out/macos`. It builds niimbench for `aarch64-macos.13.0` and `x86_64-macos.13.0`, joins them with `lipo`, makes the icon from [../packaging/macos/icon-1024.png](../packaging/macos/icon-1024.png) with `sips` and `iconutil`, signs ad hoc with `codesign --sign -`, and zips with `ditto`, which keeps the signature. It fails if the binary is not both architectures or does not report `build.zig.zon`'s version.

The bundle is two apps:

| Path in the bundle | What it is |
|---|---|
| `Contents/MacOS/niimbench` | [../packaging/macos/launcher.sh](../packaging/macos/launcher.sh), what Finder starts: `open -n` on the server app with `--app`, then it exits |
| `Contents/Helpers/niimbench.app` | The server: the universal binary, with an `Info.plist` that names Bluetooth's use |

One app would not do. macOS only brings an app that is still running forward when it is opened again, so a server that was the app itself would turn every later double-click into nothing. The launcher is gone a moment after it starts, so each double-click runs it anew, and `open -n` starts a new server, which finds the running one's lock, opens its page and exits. The server is an app of its own so that macOS asks about Bluetooth by its name and finds its usage description; both have `LSUIElement`, so neither shows in the Dock.

`make macos-app-check` runs [../tools/macos-app-check.sh](../tools/macos-app-check.sh): it opens the app, waits for the token file in Application Support, asks the server for `/api/health`, opens the app a second time and checks one server still runs, then quits it and checks the token file went with it. It refuses to run while an app server already runs.

CI's Macs cannot check three things, and a release has not yet done so on a Mac of its own: the Bluetooth prompt and printing from the app, since the runners have no Bluetooth radio, and the first open of a copy downloaded with a browser, since an app built on the runner is not marked as downloaded. `tools/macos-app.sh` reads the first one's preconditions instead: the server's `Info.plist` says why it uses Bluetooth, without which macOS ends the app, and both apps are `LSUIElement`. Before a release, try the zip the `macos-app` job keeps on its run on a Mac with a printer: download it with a browser, open it, allow Bluetooth when asked, and print. [../packaging/macos/icon.svg](../packaging/macos/icon.svg) is [assets/icon.svg](assets/icon.svg) on the macOS icon grid, and the PNG is rendered from it:

```sh
rsvg-convert -w 1024 -h 1024 packaging/macos/icon.svg -o packaging/macos/icon-1024.png
```

## CI and releases

[../.github/workflows/ci.yml](../.github/workflows/ci.yml) runs `zig fmt --check` and `make test` on every push to `main` and every pull request, on Ubuntu with the runner's own Chrome, so the browser checks run there rather than skip. A `macos` job runs `zig build test` and serves the page once on an arm64 and an Intel Mac, where the CoreBluetooth checks run instead of skipping. A `linux-packages` job builds the x86_64 tarball, `.deb` and `.rpm` and installs each in a Debian and a Fedora container, an `aur` job writes the AUR package from tarballs for both architectures and builds, installs and lints it on Arch, and a `macos-app` job builds the Mac app, starts it as Finder does, and keeps its zip as a download on the run. [../.github/workflows/release.yml](../.github/workflows/release.yml) publishes a `vX.Y.Z` tag. The version is written once, in `build.zig.zon`, which `build.zig` passes to the code as `build_options.version` and `niimbench --version` prints. Cutting a release is [cookbook/releasing.md](cookbook/releasing.md).

## Docs map

The index of every page is [README.md](README.md), and the rules for writing them are [AGENTS.md](AGENTS.md).
