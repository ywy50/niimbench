# niimbench

A local label bench for Niimbot printers, written in Zig. niimbench is inspired by [niimprint](https://github.com/AndBondStyle/niimprint).

## Quick start

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

One process serves the editor page on `127.0.0.1`, renders labels, and prints them over USB serial or Bluetooth Low Energy through BlueZ. The browser is a client of that server, and so is anything else that calls its HTTP API.

The process is a plugin tree in the sense of [Cordis](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer) ([arXiv:2608.25512](https://arxiv.org/abs/2608.25512)): every feature is mounted on a context, names what it needs, and removes its registrations on unload. The docs layout follows [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

The documentation index is [docs/README.md](docs/README.md).

## Running it

`make` listens on `127.0.0.1` with an ephemeral port, prints a URL that carries the session token, and opens it with `xdg-open`. `make serve` leaves the URL for a browser you already have. `PORT=8080` picks the port. `make help` lists the targets and variables.

`label.pgm` is a binary P5 file: `P5`, width, height, maxval `255`, then one byte per pixel. `0` is black and `255` is white.

The editor guide is [docs/user/guide/index.md](docs/user/guide/index.md). A layout you can load is [docs/templates/example-label.json](docs/templates/example-label.json).

## Editor

The page places text fields, fills them from a JSON source, and previews the bitmap the printer will get. Preview and print both go through `POST /api/render` and `POST /api/print`, which share one drawing path on the server.

Each field has its own font, a size in dots, an alignment, a position and an angle. Drag a field's box to move it, drag a corner to resize it, and drag the round handle to turn it. Text that would run off the label is marked clipped. A field that reads the selected source record says so, with the value it will draw. Sources can be added and removed while the process runs. Save layout writes JSON; Load layout reads it back. The saved file leaves out the background image.

## Fonts

Text is drawn by niimbench's own TrueType rasteriser from fonts embedded in the binary, so a print never depends on what is installed. Fifteen free fonts ship with it: DejaVu Sans, Sans Bold, Sans Mono and Serif; Liberation Sans, Sans Bold, Serif and Mono; Open Sans and Open Sans Bold; Fira Sans and Fira Sans Bold; Noto Sans and Noto Serif; and Hack. Their licences and origins are in [src/fonts/README.md](src/fonts/README.md), and how text is drawn is [docs/subsystems/text.md](docs/subsystems/text.md).

## Models

B1, B18, and B21 use a 384-pixel print head. D11 and D110 use 96. B18, D11, and D110 densities above 3 are clamped to 3. Head width, density, and the raster live in [docs/subsystems/printer.md](docs/subsystems/printer.md).

The editor scans for printers and lists what it finds under **Found Niimbot devices**. Picking one fills in the connection, the address, and the model, so the label is built for the printer that is there. The scan probes the serial ports and asks BlueZ what Bluetooth devices exist; **Find nearby** adds an inquiry. The subsystem page is [docs/subsystems/printer.md](docs/subsystems/printer.md#discovery).

USB needs a user who can open the tty (`dialout` on most Linux machines). Bluetooth goes through BlueZ on the system bus, so it needs a running `bluetoothd`; a BLE printer is written over its print characteristic.

## Layout

| Path | What it is |
|---|---|
| `src/cordis.zig` | Context, inject, reversible effects |
| `src/packet.zig`, `src/printer.zig`, `src/raster.zig` | Printer core |
| `src/label.zig` | Text layout: font, size, alignment, turning, clipping |
| `src/font.zig`, `src/fonts/` | TrueType reader and rasteriser, and the embedded fonts with their licences |
| `src/device.zig` | The USB serial and Bluetooth openers, and the two finders |
| `src/ble.zig`, `src/dbus.zig` | The BLE print channel, and the BlueZ D-Bus client it uses |
| `src/discovery.zig` | Found-device list and model lookup |
| `src/server.zig`, `src/editor.html` | HTTP API and the editor page |
| `src/plugins.zig`, `src/example_source.zig`, `cordis.patch.yml` | Boot list and plugins |
| `tools/` | The browser and node checks `make test` runs, the page lint, and the label catalogue fetcher |
| `Makefile` | `make`, `make serve`, `make test`, `make print`, `make labels` |
| `docs/` | Index, architecture, subsystems, cookbook, user guide, templates, reviews |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Agents follow [AGENTS.md](AGENTS.md).

## Development

Start with [docs/development.md](docs/development.md) and [docs/architecture.md](docs/architecture.md).

## License

niimbench is [MIT](LICENSE). The embedded fonts keep their own licences, listed in [src/fonts/README.md](src/fonts/README.md).
