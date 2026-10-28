<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="niimbench, a label editor for Niimbot label printers" width="420">
  </picture>
</p>

<p align="center">
  <em>Lay out a label in your browser, see the exact dots the print head will burn,
  and print it on a Niimbot printer over USB or Bluetooth.</em>
</p>

<p align="center">
  <a href="https://github.com/ywy50/niimbench/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/ywy50/niimbench/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/ywy50/niimbench/releases/latest"><img alt="latest release" src="https://img.shields.io/github/v/release/ywy50/niimbench?color=0b62d4"></a>
  <img alt="Zig 0.17" src="https://img.shields.io/badge/zig-0.17-f7a41d?logo=zig&logoColor=white">
  <img alt="platform: Linux, macOS" src="https://img.shields.io/badge/platform-linux%20%7C%20macOS-lightgrey">
  <img alt="printers: B1, B18, B21, D11, D110, D110_M" src="https://img.shields.io/badge/printers-B1%20%7C%20B18%20%7C%20B21%20%7C%20D11%20%7C%20D110%20%7C%20D110__M-0b62d4">
  <a href="LICENSE"><img alt="license: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

niimbench designs and prints labels on Niimbot label printers, the D110, D110_M, D11, B21, B1 and B18, from Linux or a Raspberry Pi over USB or Bluetooth, or from a Mac over Bluetooth, with no phone app or account. It is a single binary written in Zig, and it is inspired by [niimprint](https://github.com/AndBondStyle/niimprint).

## Quick start

Pick what you have. Each way ends with the editor open in your browser.

| You have | Go to |
|---|---|
| Debian or Ubuntu | [Debian or Ubuntu](#debian-or-ubuntu) |
| Fedora | [Fedora](#fedora) |
| Arch Linux | [Arch Linux](#arch-linux) |
| Another Linux, or a Raspberry Pi | [Any Linux](#any-linux) |
| A Mac | [Mac](#mac) |
| Windows | [Windows and macOS](#windows-and-macos) |
| A checkout of this repository | [From source](#from-source) |

### Debian or Ubuntu

The package also puts niimbench in your desktop menu:

```bash
curl -fsSLO https://github.com/ywy50/niimbench/releases/latest/download/niimbench-x86_64-linux.deb
sudo apt install ./niimbench-x86_64-linux.deb
```

On a 64-bit ARM machine, write `aarch64` where these say `x86_64`.

### Fedora

```bash
sudo dnf install https://github.com/ywy50/niimbench/releases/latest/download/niimbench-x86_64-linux.rpm
```

On a 64-bit ARM machine, write `aarch64` where this says `x86_64`.

### Arch Linux

The package is `niimbench-bin`, the same release build and menu entry, built from the `PKGBUILD` on the release:

```bash
mkdir niimbench-bin
cd niimbench-bin
curl -fsSLo PKGBUILD https://github.com/ywy50/niimbench/releases/latest/download/PKGBUILD
makepkg -si
```

### Any Linux

Nothing to install. On a 64-bit x86 machine:

```bash
curl -fsSL https://github.com/ywy50/niimbench/releases/latest/download/niimbench-x86_64-linux.tar.gz | tar xz
./niimbench-x86_64-linux/niimbench
```

On a 64-bit ARM machine, such as a Raspberry Pi 4 or 5 running a 64-bit OS:

```bash
curl -fsSL https://github.com/ywy50/niimbench/releases/latest/download/niimbench-aarch64-linux.tar.gz | tar xz
./niimbench-aarch64-linux/niimbench
```

### Mac

macOS 13 or later, Apple silicon or Intel. Install the app and open it:

```bash
curl -fsSLO https://github.com/ywy50/niimbench/releases/latest/download/niimbench-macos.zip
ditto -x -k niimbench-macos.zip /Applications
open /Applications/niimbench.app
```

Downloaded with a browser instead, the app needs your OK the first time: see [First open](#first-open).

### From source

You need Zig 0.17. Node and a Chromium-family browser are only needed for `make test`.

Serve the editor and open it in your browser:

```bash
make
```

Run every check:

```bash
make test
```

Print a binary PGM over USB:

```bash
make print IMAGE=label.pgm ADDR=/dev/ttyACM0
```

Print the same file over Bluetooth:

```bash
make print IMAGE=label.pgm ADDR=AA:BB:CC:DD:EE:FF CONN=bluetooth
```

Everything below is detail.

## What it is

<p align="center">
  <img src="docs/assets/editor.png" alt="The niimbench label editor for Niimbot printers: a 50×30 mm label in the preview with three text fields in their dashed boxes, beside the label and printer panel" width="900">
</p>

One process serves the editor page on `127.0.0.1`, renders labels, and prints them over USB serial or Bluetooth Low Energy, through BlueZ on Linux and CoreBluetooth on macOS. The browser is a client of that server, and so is anything else that calls its HTTP API.

- **What you see is what prints.** The preview is the grayscale the printer will get: preview and print share one drawing path on the server.
- **It finds the printer.** A scan of the serial ports and of Bluetooth fills in the connection, the address and the model, and the roll the printer reports.
- **Text in real fonts.** Fifteen free fonts are embedded and drawn by niimbench's own TrueType rasteriser, so a print never depends on what is installed.
- **Pictures in one ink.** An imported picture is reduced to black and white at a threshold, or dithered (five error diffusions, a Bayer pattern or halftone dots) after brightness, contrast, gamma and sharpening, so a photo keeps its greys as dots. Then it is moved, scaled and turned on the label.
- **A board, not a form.** Preview, printer, text and image are panels you drag by their titles and resize from a corner. This browser remembers where you put them.
- **Checked by driving it.** `make test` drives the page in a headless browser, and no server a test starts can outlive the run.

The process is a plugin tree in the sense of [Cordis](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer) ([arXiv:2608.25512](https://arxiv.org/abs/2608.25512)): every feature is mounted on a context, names what it needs, and removes its registrations on unload. The docs layout follows [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

The documentation index is [docs/README.md](docs/README.md).

## Running it

- **Start.** `make`, the desktop menu entry, the Mac app or the binary itself. niimbench listens on `127.0.0.1` with an ephemeral port, prints a URL that carries the session token, and opens it with `xdg-open` (`open` on macOS).
- **Stop.** Pick **Quit niimbench…** in the menu on the **niimbench** name. It also stops by itself once no page has been open for 30 minutes.
- **Start it again while it runs.** That opens the running one instead of a second server ([docs/user/guide/index.md](docs/user/guide/index.md#stop-and-start-again)).
- **Other ways to run it.** `make serve` leaves the URL for a browser you already have. `PORT=8080` picks the port. `make help` lists the targets and variables.

### The desktop menu entry

- The `.deb` and `.rpm` install `niimbench` in `/usr/bin` and a **niimbench** entry in the desktop menu, which runs `niimbench --app`.
- From the menu, the editor opens in your browser, and picking the entry again while it runs opens the running one.
- Its lock and token file live in `~/.local/state/niimbench`, rather than in whatever folder the menu starts it in.
- Each tarball carries the same entry and its icons under `share/`. With the binary on your `PATH`, copy that folder into `~/.local/share` for a menu entry of your own.

### Next steps

- The editor guide is [docs/user/guide/index.md](docs/user/guide/index.md).
- A layout you can load is [docs/templates/example-label.json](docs/templates/example-label.json).
- `label.pgm`, for `make print`, is a binary P5 file: `P5`, width, height, maxval `255`, then one byte per pixel. `0` is black and `255` is white.

## Editor

The page places text fields and previews the bitmap the printer will get. Preview and print both go through `POST /api/render` and `POST /api/print`, which share one drawing path on the server.

Each field has its own font, a size in dots, a position and an angle. Drag a field's box to move it, drag a corner to resize it, and drag the round handle to turn it. Text that would run off the label is marked clipped. Save layout writes JSON; Load layout reads it back. The saved file leaves out the background image.

The editor draws literal text. The HTTP routes also take a JSON `source` and a field `key` to fill a field from, and sources can be added and removed while the process runs: [docs/subsystems/sources.md](docs/subsystems/sources.md).

## Printers

| Model | Print head | Density |
|---|---|---|
| B1 | 384 dots | 1 to 5 |
| B18 | 384 dots | 1 to 3 |
| B21 | 384 dots | 1 to 5 |
| D11 | 96 dots | 1 to 3 |
| D110 | 96 dots | 1 to 3 |
| D110_M | 96 dots | 1 to 5 |

B18, D11, and D110 densities above 3 are clamped to 3. Head width, density, and the raster live in [docs/subsystems/printer.md](docs/subsystems/printer.md).

The editor scans for printers and lists what it finds under **Found Niimbot devices**. Picking one fills in the connection, the address, and the model, so the label is built for the printer that is there.

- **On Linux** the scan probes the serial ports and asks BlueZ what Bluetooth devices exist. **Find nearby** adds an inquiry.
- **On a Mac** it lists the printers already connected. **Find nearby** listens for advertisements.

How finding works is [docs/subsystems/printer.md](docs/subsystems/printer.md#discovery).

| Connection | What it needs |
|---|---|
| USB on Linux | A user who can open the tty: `dialout` on most Linux machines |
| Bluetooth on Linux | BlueZ on the system bus, so a running `bluetoothd`. A BLE printer is written over its print characteristic |
| Bluetooth on macOS | niimbench allowed to use Bluetooth, under System Settings → Privacy & Security → Bluetooth; run from a checkout, the terminal app instead |
| USB on macOS | Not supported yet |

## Fonts

Text is drawn by niimbench's own TrueType rasteriser from fonts embedded in the binary, so a print never depends on what is installed. Fifteen free fonts ship with it:

| Family | Faces |
|---|---|
| Fira Sans | Book, Bold |
| DejaVu | Sans, Sans Bold, Sans Mono, Serif |
| Liberation | Sans, Sans Bold, Serif, Mono |
| Open Sans | Regular, Bold |
| Noto | Sans, Serif |
| Hack | Regular, monospaced |

Their licences and origins are in [src/fonts/README.md](src/fonts/README.md), and how text is drawn is [docs/subsystems/text.md](docs/subsystems/text.md).

## Windows and macOS

niimbench reaches a printer through the operating system's own interfaces. On Linux those are BlueZ for Bluetooth and the kernel's serial ports for USB. On macOS it is Apple's CoreBluetooth, so a Mac prints over Bluetooth; USB on a Mac is not supported yet.

### The Mac app

`niimbench.app` comes in `niimbench-macos.zip` on the releases page. It runs on macOS 13 or later, on Apple silicon and on Intel.

- **Opening it** opens the editor in your browser. It has no window or Dock icon of its own: the page is the app.
- **Opening it again** while it runs opens its page.
- **Quitting:** pick **Quit niimbench…** in the page's menu. It also stops by itself 30 minutes after the last page closed.
- **Its files:** the lock and token file are in `~/Library/Application Support/niimbench`.

### First open

The app is signed ad hoc, not with an Apple Developer ID, and it is not notarized. Downloaded with a browser, its first open is refused with a message that Apple could not verify niimbench. Allow it once:

- **macOS 15:** open System Settings → Privacy & Security, and pick **Open Anyway** next to that message.
- **macOS 13 and 14:** Control-click the app and pick **Open**.

A copy fetched with `curl`, as in the quick start, is not marked as downloaded and opens without asking.

### Bluetooth on a Mac

- The first scan asks whether niimbench may use Bluetooth. Allow it, or later turn it on under System Settings → Privacy & Security → Bluetooth. Until then a print answers `BluetoothNotAllowed`.
- Run from a checkout with `make`, it is your terminal app that macOS asks about instead.
- macOS does not show programs a Bluetooth address. The printer list shows a UUID your Mac made up for the printer, and that UUID is the address to print to.
- CI checks the macOS code on GitHub's Macs, which have no Bluetooth radio, so printing from a Mac has not yet been tried against a real printer.

From source, Zig 0.17 serves the editor from the checkout with `make`, and `make macos-app` builds the app into `zig-out/macos` ([docs/development.md](docs/development.md#the-mac-app)).

### Windows

- The Linux build runs inside WSL 2. Start it there and open the address it prints in your Windows browser, which WSL forwards to it.
- A printer on USB, such as the B21, is reached once [usbipd-win](https://github.com/dorssel/usbipd-win) attaches it to WSL, where it shows up as `/dev/ttyACM0`.
- Bluetooth is not available inside WSL, so a Bluetooth-only printer such as the D110 cannot print from there.

## Releases

Each release on the [releases page](https://github.com/ywy50/niimbench/releases) has these files:

| File | What it is |
|---|---|
| `niimbench-x86_64-linux.tar.gz`, `niimbench-aarch64-linux.tar.gz` | A static `niimbench` binary, which needs no libc or other library, with `LICENSE`, this README, `CHANGELOG.md`, the licences of the fonts compiled into the binary, and a desktop menu entry with its icons under `share/` |
| `niimbench-x86_64-linux.deb`, `niimbench-aarch64-linux.deb` | The same files, installed where the system looks for them. They recommend BlueZ and `xdg-utils` and depend on nothing |
| `niimbench-x86_64-linux.rpm`, `niimbench-aarch64-linux.rpm` | The same as the `.deb`, for Fedora and other RPM systems |
| `PKGBUILD` | The Arch package `niimbench-bin`, written from the tarballs' checksums |
| `niimbench-macos.zip` | The Mac app, with one binary for both kinds of Mac |

Every file comes with a `.sha256` and a build provenance attestation signed by the release workflow.

Check a Linux download before you run it, the same way for the `.deb` and the `.rpm`:

```bash
sha256sum -c niimbench-x86_64-linux.tar.gz.sha256
gh attestation verify niimbench-x86_64-linux.tar.gz --repo ywy50/niimbench
```

Check the Mac app:

```bash
shasum -a 256 -c niimbench-macos.zip.sha256
gh attestation verify niimbench-macos.zip --repo ywy50/niimbench
```

`niimbench --version` prints the version, and [CHANGELOG.md](CHANGELOG.md) says what each one changed. Cutting a release is [docs/cookbook/releasing.md](docs/cookbook/releasing.md).

## Layout

| Path | What it is |
|---|---|
| `src/main.zig`, `src/root.zig` | The CLI: serve, print, version, its flags, and the one-server lock |
| `src/cordis.zig`, `src/load.zig`, `src/patch.zig` | Context, inject and reversible effects, and loading and mounting the boot list |
| `src/plugins.zig`, `src/default.patch.yml`, `cordis.patch.yml` | The plugin catalogue, and the boot list compiled in and on disk |
| `src/server.zig`, `src/editor.html` | The HTTP API with the plugins that serve it, and the editor page |
| `src/packet.zig`, `src/printer.zig`, `src/raster.zig` | Printer core: frames, the print sequences, the raster, and the model table and roll sizes |
| `src/label.zig` | Text layout: font, size, alignment, turning, clipping |
| `src/font.zig`, `src/fonts/` | TrueType reader and rasteriser, and the embedded fonts with their licences |
| `src/device.zig` | The USB serial and Bluetooth openers, and the finders |
| `src/ble.zig`, `src/dbus.zig` | Linux: the BLE print channel, and the BlueZ D-Bus client it and the finder use |
| `src/corebluetooth.zig` | macOS: the Bluetooth finder and print channel, through CoreBluetooth |
| `src/discovery.zig` | Found-device list, the finder registry, and the model lookup |
| `src/labels_catalogue.zig`, `src/catalogue.json` | The label roll catalogue compiled into the binary |
| `src/trace.zig` | The in-memory log, published as the `trace` service |
| `src/example_source.zig` | The example JSON source, a plugin |
| `tools/` | The browser and node checks `make test` runs, and the page lint |
| `tools/with-server.sh`, `tools/drive.js`, `tools/trace.sh`, `tools/harness.patch.yml` | The throwaway-server and browser-driving harness |
| `tools/fetch-labels.py` | The label catalogue fetcher |
| `tools/linux-dist.sh`, `tools/linux-package-check.sh`, `tools/get-nfpm.sh` | The Linux release and package builds, and their checks |
| `tools/aur.sh`, `tools/aur-check.sh`, `tools/aur-push.sh` | The Arch package's build, check and AUR publishing |
| `tools/macos-app.sh`, `tools/macos-app-check.sh` | The Mac app's build and check |
| `packaging/linux/` | The desktop menu entry, and the nfpm config the `.deb` and `.rpm` are made from |
| `packaging/aur/` | The template each release's Arch `PKGBUILD` is written from |
| `packaging/macos/` | The Mac app's two `Info.plist` files, its launcher, and its icon on the macOS grid |
| `docs/assets/` | The logo kit, and the README's screenshot with the steps that take it ([docs/assets/README.md](docs/assets/README.md)) |
| `Makefile` | `make`, `make serve`, `make trace`, `make test`, `make drive`, `make print`, `make labels`, `make macos-app`; `make help` lists every target |
| `.github/workflows/` | CI on every push to `main` and every pull request, on Linux and on Intel and Apple Silicon Macs, and the tag-driven release |
| `CHANGELOG.md` | What each release changed |
| `docs/` | Index, architecture, subsystems, cookbook, user guide, templates, reviews |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Agents follow [AGENTS.md](AGENTS.md).

## Development

Start with [docs/development.md](docs/development.md) and [docs/architecture.md](docs/architecture.md).

## License

niimbench is [MIT](LICENSE). The embedded fonts keep their own licences, listed in [src/fonts/README.md](src/fonts/README.md).
