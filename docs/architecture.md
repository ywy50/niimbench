# Architecture

niimbench is one process with three layers. Plugins are how the top two layers are assembled. The printer core is the small set of functions those plugins call.

```text
browser (opened with xdg-open, or open on macOS)
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
   packet codec, raster,   USB serial,           dbus (BlueZ, Linux),
   label + font, Client    BLE via ble.zig       corebluetooth (macOS),
                           or corebluetooth      packet codec probe
   every layer writes lines to the trace service, readable while the process runs
```

## Printer core

`packet.zig` frames `55 55 | type | len | data | xor | AA AA`. `printer.zig` sends the print sequence. Its order depends on the model and, on the D-series, on the protocol version the printer reports: setup commands, the image rows, sent as runs of blank and repeated rows, end page, then `PrintEnd` once `PrintStatus` shows the job printed ([subsystems/printer.md](subsystems/printer.md#wire)). `raster.zig` turns grayscale into those rows. Bit 1 is a burned dot.

Dimension words are height then width: `SetPageSize` reads its first word as the page's length down the tape ([subsystems/printer.md](subsystems/printer.md#raster)).

`device.zig` opens the two transports and probes serial ports. `discovery.zig` is the found-device list, the finder registry, and the model lookup. `dbus.zig` is the D-Bus client the Bluetooth finder asks BlueZ with, and `ble.zig` writes print frames to a BLE printer through it. On macOS `corebluetooth.zig` is both the Bluetooth finder and the print channel, through Apple's CoreBluetooth.

`label.zig` lays a field's text out — font, size, alignment, angle — and `font.zig` draws it from the fonts embedded in the binary. How a line is measured and how glyphs are filled is [subsystems/text.md](subsystems/text.md).

## App backend

`server.zig` holds the `http` plugin, and the `printer`, `transports`, `devices`, `sources` and `editor` plugins beside it. `http` binds `127.0.0.1`, generates a token, and serves the editor page and the API; the routes are the table in [subsystems/http.md](subsystems/http.md).

Every route requires the session token. Startup prints it on `?token=`. A browser that opens that URL gets an `HttpOnly` cookie and a redirect to `/`, so the address bar does not keep the token. `curl` can still pass `?token=`. The server is not bound to any other interface. It runs until the page's **Quit**, or until no page has been open for 30 minutes ([subsystems/http.md](subsystems/http.md#session)).

`print` on the command line loads the same plugin tree and calls `PrinterService.submit`. It does not open a second protocol implementation.

## Editor

`src/editor.html` places text fields; it has no source controls. Preview and print both call `compose` in `server.zig`, which calls `label.render` or `label.renderOnto`, so the page shows the pixels that will be sent, except the page margin: a print leaves the model's margin off the end of the label, and the page hatches that strip. A background image is optional and is drawn under the text. A field's own `rotation` turns its letters; the bytes sent to the printer stay the roll's width. The editor's Orientation turns only the preview, so the label can be seen the way it reads.

The page draws a dashed box over each field using `/api/label/metrics`, the same numbers `label.zig` renders with, and drags a field by its box or resizes it by a corner. A field whose text would cross an edge is marked clipped, which is what the renderer does with it. `/api/label/track` tells the page where each field's line starts and what text it will draw. The printer row comes from `/api/devices/scan`: the page lists what was found and writes the connection, address, and model of the one that is picked. Save layout writes the label body and printer fields as JSON, and Load layout reads one back. The walkthrough is [user/guide/index.md](user/guide/index.md). A file in that shape is [templates/example-label.json](templates/example-label.json). The documentation index is [README.md](README.md).

Besides drawing and printing, the page reads the roll from a picked printer (`/api/label/roll`), syncs the printer's clock (`/api/printer/clock`), stops the server from its menu (`/api/quit`), checks in once a minute (`/api/health`) so an open page keeps the server running, and posts its own steps to the [trace](subsystems/trace.md).

## Boot

`src/load.zig` parses `cordis.patch.yml` and mounts each row. A plugin whose `inject` keys are missing stays inactive until they appear. Disposing a fiber runs its effects in reverse, which drops services, routes, and openers that depended on it.

The embedded patch is `src/default.patch.yml`. A `cordis.patch.yml` in the current directory replaces it for that run.
