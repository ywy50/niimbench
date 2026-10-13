# Architecture

niimbench is one process with three layers. Plugins are how the top two layers are assembled. The printer core is the small set of functions those plugins call.

```text
browser or xdg-open
        |
        |  HTTP on 127.0.0.1, token in the query
        v
   http plugin  ---- sources plugin ---- json-source plugin
        |
        |  injects printer, transports, sources
        v
   printer service          transport registry
                            usb opener, bluetooth opener
        |
        v
   packet codec, raster, Client
```

## Printer core

`packet.zig` frames `55 55 | type | len | data | xor | AA AA`. `printer.zig` sends the same print sequence as niimprint: density, label type, start, page, dimension, one `0x85` row per scan line, end page, end print. `raster.zig` turns grayscale into those rows. Bit 1 is a burned dot.

Dimension words are height then width, because niimprint calls `set_dimension(image.height, image.width)`.

## App backend

`server.zig` is the `http` plugin. It binds `127.0.0.1`, generates a token, and serves:

| Method | Path | Role |
|---|---|---|
| GET | `/` | Editor page |
| GET | `/api/health` | Liveness |
| GET | `/api/ports` | `ttyACM*` and `ttyUSB*` under `/dev` |
| GET | `/api/sources` | Names of installed sources |
| GET | `/api/sources/<name>` | One JSON record |
| POST | `/api/print` | Raster, open a transport, print |

Every route requires `?token=`. The token is printed on stdout at startup. The server is not bound to any other interface.

`print` on the command line loads the same plugin tree and calls `PrinterService.submit`. It does not open a second protocol implementation.

## Editor

`src/editor.html` is the page. It draws the chosen image, rotates it on the canvas, and posts grayscale pixels. Filling a label from another system is a source plugin: the page asks `/api/sources/...`, and the server does the read.

## Boot

`src/load.zig` parses `cordis.patch.yml` and mounts each row. A plugin whose `inject` keys are missing stays inactive until they appear. Disposing a fiber runs its effects in reverse, which drops services, routes, and openers that depended on it.

The embedded patch is `src/default.patch.yml`. A `cordis.patch.yml` in the current directory replaces it for that run.
