# Architecture

niimbench is one process with three layers. Plugins are how the top two layers are assembled. The printer core is the small set of functions those plugins call.

```text
browser or xdg-open
        |
        |  HTTP on 127.0.0.1, token in the query
        v
   http plugin  ---- sources plugin ---- json-source plugin
        |     |
        |     `--------- trace plugin (the log every layer writes to)
        |
         |  injects printer, transports, devices, sources; the trace branch is optional
        v
   printer service      transport registry      device registry
                        usb opener              usb finder
                        bluetooth opener        bluetooth finder
        |                       |                      |
        v                       v                      v
   packet codec, raster,   USB serial,           dbus (BlueZ),
   label + font, Client    BLE via ble.zig       packet codec probe
   every layer writes lines to the trace service, readable while the process runs
```

## Printer core

`packet.zig` frames `55 55 | type | len | data | xor | AA AA`. `printer.zig` sends the print sequence a Niimbot printer expects: density, label type, start, page, dimension, one `0x85` row per scan line, end page, end print. `raster.zig` turns grayscale into those rows. Bit 1 is a burned dot.

Dimension words are height then width: `SetPageSize` reads its first word as the page's length down the tape ([subsystems/printer.md](subsystems/printer.md#raster)).

`device.zig` opens the two transports and probes serial ports. `discovery.zig` is the found-device list, the finder registry, and the model lookup. `dbus.zig` is the D-Bus client the Bluetooth finder asks BlueZ with, and `ble.zig` writes print frames to a BLE printer through it.

`label.zig` lays a field's text out — font, size, alignment, angle — and `font.zig` draws it from the fonts embedded in the binary. How a line is measured and how glyphs are filled is [subsystems/text.md](subsystems/text.md).

## App backend

`server.zig` is the `http` plugin. It binds `127.0.0.1`, generates a token, and serves:

| Method | Path | Role |
|---|---|---|
| GET | `/` | Editor page |
| GET | `/api/health` | Liveness |
| GET | `/api/ports` | `ttyACM*` and `ttyUSB*` under `/dev` |
| GET | `/api/devices` | Printers the last scan found |
| POST | `/api/devices/scan` | Run the scan and answer with what it found |
| GET | `/api/sources` | Names of installed sources |
| POST | `/api/sources` | Install a record at runtime |
| GET | `/api/runtime-sources` | Names `DELETE` accepts |
| GET | `/api/sources/<name>` | One JSON record |
| DELETE | `/api/sources/<name>` | Drop a record installed at runtime |
| GET | `/api/label/metrics` | Every embedded font's advance table |
| GET | `/api/label/sizes` | Die-cut rolls for each model, with pixel width and height |
| POST | `/api/label/track` | What each field draws |
| POST | `/api/render` | Draw fields onto a grayscale label |
| POST | `/api/print` | Draw the same way, then print |

Every route requires the session token. Startup prints it on `?token=`. A browser that opens that URL gets an `HttpOnly` cookie and a redirect to `/`, so the address bar does not keep the token. `curl` can still pass `?token=`. The server is not bound to any other interface.

`print` on the command line loads the same plugin tree and calls `PrinterService.submit`. It does not open a second protocol implementation.

## Editor

`src/editor.html` places text fields; it has no source controls. Preview and print both call `compose` in `server.zig`, which calls `label.render` or `label.renderOnto`, so the page shows the pixels that will be sent. A background image is optional and is drawn under the text. A field's own `rotation` turns its letters; the bytes sent to the printer stay the roll's width. The editor's Orientation turns only the preview, so the label can be seen the way it reads.

The page draws a dashed box over each field using `/api/label/metrics`, the same numbers `label.zig` renders with, and drags a field by its box or resizes it by a corner. A field whose text would cross an edge is marked clipped, which is what the renderer does with it. `/api/label/track` tells the page where each field's line starts and what text it will draw. The printer row comes from `/api/devices/scan`: the page lists what was found and writes the connection, address, and model of the one that is picked. Save layout writes the label body and printer fields as JSON, and Load layout reads one back. The walkthrough is [user/guide/index.md](user/guide/index.md). A file in that shape is [templates/example-label.json](templates/example-label.json). The documentation index is [README.md](README.md).

## Boot

`src/load.zig` parses `cordis.patch.yml` and mounts each row. A plugin whose `inject` keys are missing stays inactive until they appear. Disposing a fiber runs its effects in reverse, which drops services, routes, and openers that depended on it.

The embedded patch is `src/default.patch.yml`. A `cordis.patch.yml` in the current directory replaces it for that run.
