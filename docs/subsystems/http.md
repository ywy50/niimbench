# HTTP

The `http` plugin injects `trace`, `printer`, `transports`, `devices`, and `sources`. Only `trace` is optional: a context without it serves every route and records nothing. Its `apply` creates `HttpService`, publishes it as `"http"`, and registers the `/api/` routes below. It also owns one `ctx.effect` for source records installed at runtime, so disposing that fiber drops them.

The `editor` plugin injects `http` and registers `GET /`. Disposing that fiber removes the route. The page bytes live in `src/editor.html` and are embedded.

| Method | Path | Role |
|---|---|---|
| GET | `/api/health` | Liveness |
| GET | `/api/ports` | `ttyACM*` and `ttyUSB*` under `/dev` |
| GET | `/api/devices` | The printers the last scan found |
| POST | `/api/devices/scan` | Scan for printers and answer with what was found |
| GET | `/api/sources` | Names of installed sources |
| POST | `/api/sources` | Install `{"name": "...", "json": "{...}"}` at runtime |
| GET | `/api/runtime-sources` | Names `DELETE` accepts |
| GET | `/api/sources/<name>` | One JSON record |
| DELETE | `/api/sources/<name>` | Drop a record installed at runtime |
| GET | `/api/label/metrics` | Every embedded font's advance table, for editor boxes |
| GET | `/api/label/sizes` | Die-cut rolls for each model, with the pixel width and height |
| POST | `/api/label/track` | What each field draws, and where it came from |
| POST | `/api/label/roll` | The roll in the printer, sized for the model |
| GET | `/api/trace` | What has happened so far, one line per event |
| POST | `/api/trace` | A line from the page |
| POST | `/api/render` | Draw fields onto a grayscale label |
| POST | `/api/print` | Draw the same way, then print |

`/api/sources/<name>` picks its own method, so it sits outside the route table: `GET` reads the record, `DELETE` drops it, anything else is 404. A record a plugin added answers `source belongs to a plugin`, because only the plugin's fiber owns that lifetime.

## Session

The listen address is `127.0.0.1` and the port comes from `ctx.http_port` (`0` asks the kernel for a free port). Startup writes one line to stdout:

```text
http://127.0.0.1:<port>/?token=<32 hex chars>
```

Pass `--no-open` to skip `xdg-open`. The token is generated with `getrandom` for that process only.

`GET /?token=` answers `302` with `Set-Cookie: niimbench=<token>; HttpOnly; Path=/; SameSite=Strict` and `Location: /`. The next request sends that cookie and receives the page. API calls from the page send the cookie and do not put the token back on the URL. A request with neither a matching query token nor that cookie is `401`.

## Devices

`GET /api/devices` answers the last scan and whether one has run:

```json
{"scanned":true,"devices":[{"conn":"usb","addr":"/dev/ttyACM0","name":"NIIMBOT B21","model":"b21","model_id":768,"spp":false}]}
```

`POST /api/devices/scan` runs the scan and answers in the same shape. An empty body, or a body that is not JSON, is the passive scan: the serial probe plus the devices BlueZ already knows. `{"discover":true}` also starts a Bluetooth inquiry, which takes about two seconds.

`model` is null when the model id, or a Bluetooth name, is not one of the five heads this bench prints to. `model_id` is 0 for a Bluetooth device, because a name is the only signal there. `spp` says the device advertises the Bluetooth serial profile. The finders and the model table are in [printer.md](printer.md).

## Label body

`POST /api/render` and `POST /api/print` take the same label body.

```json
{
  "width": 384,
  "height": 96,
  "source": "example",
  "fields": [{ "key": "sku", "text": "", "x": 4, "y": 4, "size": 16, "font": "dejavu-sans", "rotation": 90 }],
  "density": 5,
  "model": "b21",
  "conn": "usb",
  "addr": "/dev/ttyACM0"
}
```

`source` is the registry name. Each field draws `text`, unless `key` is set, in which case the value comes from that source object. `background_b64` is optional grayscale laid under the text. Lines that would pass the right or bottom edge are clipped, not wrapped.

Each field takes `text`, `key`, `x`, `y`, `font`, `size`, `align_mode`, and `rotation`.

`font` is the id of an embedded font, `dejavu-sans` when it is left out, and `size` is the line height in dots, 16 when it is left out. What both mean, how a line is measured, and how its letters are drawn is [text.md](text.md). A font the build does not carry is `UnknownFont`.

`rotation` is the field's own angle in degrees, clockwise about the centre of its block: `0` is the letters across the head's width, `90` along the tape, and anything from `0` to `359` is allowed, including the angles between. The angle turns the letters only — it never resizes the page, and it is the **only** thing that turns a field. `direction` is accepted for older callers and ignored: a field is turned by `rotation`. Turning the page is not this and is not something the composed routes do.

A newline in `text` (or in a value a `key` resolves to) starts a second line, `size` dots below the previous one, so a field is a block of lines. A blank line advances without drawing.

`align_mode` is `left`, `center`, or `right` and decides what `x` means: the left edge, the centre, or the right edge of the block, measured after `key` is resolved ([text.md](text.md#placement-and-turning)). Any other value is `BadAlign`.

A body with no `fields` and no background still prints raw `pixels_b64`, which is the path used before the editor drew text:

```json
{
  "width": 8,
  "height": 1,
  "density": 3,
  "model": "b21",
  "conn": "usb",
  "addr": "/dev/ttyACM0",
  "pixels_b64": "<base64 grayscale>"
}
```

`pixels_b64` is raw grayscale, one byte per pixel, not a PNG.

The render answer and the print are always the roll: width across the head, height along the tape. Neither route turns the page. `rotate` is still accepted in a body for older callers and does nothing; the CLI's `--rotate` turns a raw PGM page before sending it, which is a different path and the only place a page is turned.

The editor's **Orientation** buttons are not this either. They turn the picture in the window for display and are never sent: the width and height the server sees are the page's own whichever way the editor is showing it.

## The roll

`POST /api/label/roll` reads the roll's barcode from the printer's tag and answers the roll's size in millimetres and in dots — the whole label, which is what the Width and Height fields are set to. The margin that keeps the gap sensor happy belongs to `compose`, the one place a page is drawn, so a 12×40 roll answers 96×320 and the page drawn on it is 304 rows. It carries the preset id when this bench has a row for it.

The barcode is resolved from the catalogue compiled into the binary, which holds every roll the vendor lists, so the answer needs no network and no configuration. The body may set `"allow_cloud": true` to permit a second attempt against the vendor's cloud for a barcode the catalogue does not carry; without it such a barcode is `unknown roll`. The answer's `source` says which resolved it, and the editor shows `(cloud)` when it was the cloud. The editor picks a printer and takes the canvas from this answer, so the roll sets the size rather than the person. The catalogue itself is [../labels/README.md](../labels/README.md).

## Failures

`render` answers a failure in the same shape as a success, including the label size, so the page can draw an empty label instead of keeping a stale preview:

```json
{ "error": "UnknownSource", "width": 384, "height": 96 }
```

`NothingToPrint` is a `render` body with no fields, no background, and no `pixels_b64`. `UnknownSource` is a 404. Everything else is 400. The `sources` routes answer `{"error":"..."}` only.

After a successful print the context emits `print/done`.

## Metrics

`GET /api/label/metrics` returns every embedded font's measuring table, so the boxes the editor draws, and resizes live while a corner is dragged, match the ink without asking the server on every pointer move:

```json
{
  "default": "dejavu-sans",
  "max_size": 1024,
  "fonts": [
    { "id": "dejavu-sans", "name": "DejaVu Sans", "line_units": 2384, "missing": 1229, "advances": [[32, 651, 821, 942]] }
  ]
}
```

`id` is what a field's `font` names and `name` is what the editor shows. `line_units` is the font's line height in its own units and `missing` is the advance of its missing-glyph box. `advances` is a list of runs: `[first, a0, a1, ...]` is the advance of code point `first`, then of `first + 1`, and so on, for every character the font maps. A line's width in dots is `ceil(units * size / line_units)`, where `units` sums the advances of its code points, `missing` for one the table lacks. That is the integer `label.zig` computes ([text.md](text.md#width)).

## Tracking

`POST /api/label/track` answers one entry per field, in order:

```json
{
  "source": "example",
  "fields": [{ "key": "sku" }, { "text": "hand written" }, { "key": "nothing" }]
}
```

```json
{"fields":[{"origin":"record","text":"NB-1"},{"origin":"literal"},{"origin":"missing-key"}]}
```

Each entry also carries `x`, the block's left edge as the renderer places it. It is negative for a centred or right-aligned block that starts left of the label.

`origin` is one of:

| Value | Meaning |
|---|---|
| `literal` | The field has no `key`, so it draws its own `text` |
| `record` | The key resolved in `source`; `text` is what the renderer will draw |
| `missing-key` | `source` is installed but carries no such key |
| `unknown-source` | `source` is empty or not installed |
| `structured` | The value is an object or array, which draws as empty text |
| `dynamic` | The record has no value here that can be reported as plain text |

Every entry also carries `x`, the left edge of the line after its alignment, and `text` when a value resolved. The editor draws its selection box at that `x` and sizes it from that `text`, so the box matches the ink even when `center` or `right` moved the line.

The editor uses this to say which field reads the selected record, instead of guessing from the field text. Resolving the value server-side keeps one implementation of `label.resolve`.

A field whose `font` the build does not carry is refused the way `render` refuses it: 400 with `{"error":"UnknownFont"}`.

## Listening

The listener reads a request body only when the head announced a `content-length`. A method that may carry a body does not have to, and reading to end-of-stream on a body that never arrives would block the single-threaded accept loop.
