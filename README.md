# niimbench

A local label bench for Niimbot printers. One Zig process serves the editor, accepts the same calls from a browser, and prints over USB serial or Bluetooth Classic RFCOMM.

The packet layout follows [niimprint](https://github.com/AndBondStyle/niimprint) and [niimprint-rs](https://github.com/shellixyz/niimprint-rs). The process is a plugin tree in the sense of [Cordis](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer) ([arXiv:2608.25512](https://arxiv.org/abs/2608.25512)): every feature is mounted on a context, names what it needs, and removes its registrations on unload.

```bash
zig build test
zig build run -- --no-open
zig build run -- print --image label.pgm --addr /dev/ttyACM0 --model b21
```

`zig build run` listens on `127.0.0.1` with an ephemeral port, prints a URL that carries the session token, and opens it with `xdg-open`. `--no-open` leaves the URL for a browser you already have. The desktop window and the browser are two clients of that one server.

## Layout

| Path | What it is |
|---|---|
| `src/cordis.zig` | Context, inject, reversible effects |
| `src/packet.zig`, `src/printer.zig`, `src/raster.zig` | Printer core |
| `src/device.zig` | USB serial and RFCOMM openers |
| `src/server.zig`, `src/editor.html` | HTTP API and the editor page |
| `src/plugins.zig`, `cordis.patch.yml` | Boot list |
| `docs/` | Architecture, subsystems, cookbook, reviews |

The documentation map is in [docs/architecture.md](docs/architecture.md).

## Models

B1, B18, and B21 use a 384-pixel print head. D11 and D110 use 96. B18, D11, and D110 densities above 3 are clamped to 3. The CLI reads binary PGM (`P5`). The editor sends the preview pixels itself.

USB needs a user who can open the tty (`dialout` on most Linux machines). Bluetooth is Classic RFCOMM channel 1, the same socket niimprint opens.
