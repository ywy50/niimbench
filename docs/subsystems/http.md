# HTTP

The `http` plugin injects `printer`, `transports`, `devices`, and `sources`. `trace` is optional: a context without it serves every route and records nothing, and withdrawing it later degrades the two trace routes to a `404` instead of dropping the fiber. Its `apply` creates `HttpService`, publishes it as `"http"`, and registers the `/api/` routes below. It also owns one `ctx.effect` for source records installed at runtime, so disposing that fiber drops them.

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
| GET | `/api/label/sizes` | `dots_per_mm`, and per model its `max_width`, `max_density`, `page_margin`, `default` roll and die-cut rolls with their pixel width and height |
| POST | `/api/label/track` | What each field draws, and where it came from |
| POST | `/api/label/roll` | The roll in the printer, sized for the model |
| POST | `/api/printer/clock` | Set the printer's clock to the time the page sends |
| POST | `/api/printer/info` | Ask the printer for its model id, firmware version and hardware version |
| POST | `/api/quit` | Stop the server, from the menu on the page's niimbench name |
| GET | `/api/trace` | What has happened so far, one line per event |
| POST | `/api/trace` | A line from the page |
| POST | `/api/render` | Draw fields onto a grayscale label |
| POST | `/api/print` | Draw the same way, then print |

`/api/sources/<name>` picks its own method, so it sits outside the route table: `GET` reads the record, `DELETE` drops it, anything else is 404. The name is percent-decoded, so a source named `my record` is `/api/sources/my%20record`. A record a plugin added answers `source belongs to a plugin`, because only the plugin's fiber owns that lifetime.

## Session

The listen address is `127.0.0.1` and the port comes from `ctx.http_port` (`0` asks the kernel for a free port). Startup writes one line to stdout:

```text
http://127.0.0.1:<port>/?token=<32 hex chars>
```

`--port N` picks the port. Pass `--no-open` to skip opening the page with `xdg-open` (Linux) or `open` (macOS). `--parent PID` makes the server die with its parent, which is how the harnesses start it ([../development.md](../development.md#throwaway-servers)). The token is random for that process only, from `getrandom` on Linux and `arc4random_buf` on macOS.

`GET /?token=` answers `302` with `Set-Cookie: niimbench-<port>=<token>; HttpOnly; Path=/; SameSite=Strict` and `Location: /`, so the address bar no longer shows the token. The cookie's name carries the port because a browser keeps one cookie per name for `127.0.0.1` whatever the port, and two servers running at once would otherwise each sign the other's page out. The next request sends that cookie and receives the page, with the token written into it, and the page's own API calls carry it as `?token=`. A cookie named plain `niimbench` is still read. A request with neither a matching query token nor such a cookie is `401`.

The server stops on its own in two cases. `POST /api/quit` sets a flag, and `serve` returns after that request. `serve` also returns when no request has arrived for `--idle-minutes`, 30 by default; `0` never stops. An open page calls `GET /api/health` every half minute, so only a server with no page left stops. What a second start from the same directory does is in [../development.md](../development.md#process-lifetime).

## Devices

`GET /api/devices` answers the last scan and whether one has run:

```json
{"scanned":true,"devices":[{"conn":"usb","addr":"/dev/ttyACM0","name":"NIIMBOT B21","model":"b21","model_id":768,"spp":false}]}
```

`POST /api/devices/scan` runs the scan and answers in the same shape. An empty body, or a body that is not JSON, is the passive scan: the serial probe plus the devices BlueZ already knows. `{"discover":true}` also starts a Bluetooth inquiry, which takes about two seconds.

When a finder of the scan failed, the answer keeps the finding it made anyway and carries the failure with it — `"scan_error":"bluetooth:BusUnavailable"` names the transport and the cause — so a partial scan does not read as a clean one. The scan's trace line says the same.

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

`source` is the registry name. Each field draws `text`, unless `key` is set, in which case the value comes from that source object. `background_b64` is optional and laid under the text: either grayscale, one byte per pixel, or 1 bit per pixel packed most significant bit first, a row padded to whole bytes, which is what the editor sends. Any other length is `BadPixels`. Lines that would pass the right or bottom edge are clipped, not wrapped.

Each field takes `text`, `key`, `x`, `y`, `font`, `size`, `align_mode`, and `rotation`.

`font` is the id of an embedded font, `fira-sans-bold` when it is left out, and `size` is the line height in dots, 16 when it is left out. What both mean, how a line is measured, and how its letters are drawn is [text.md](text.md). A font the build does not carry is `UnknownFont`.

`rotation` is the field's own angle in degrees, clockwise about the centre of its block: `0` is the letters across the head's width, `90` along the tape, and anything from `0` to `359` is allowed, including the angles between. The angle turns the letters only — it never resizes the page, and it is the **only** thing that turns a field. `direction` is accepted for older callers and ignored: a field is turned by `rotation`. Turning the page is not this and is not something the composed routes do.

A newline in `text` (or in a value a `key` resolves to) starts a second line, `size` dots below the previous one, so a field is a block of lines. A blank line advances without drawing.

`align_mode` is `left`, `center`, or `right` and decides what `x` means: the left edge, the centre, or the right edge of the block, measured after `key` is resolved ([text.md](text.md#placement-and-turning)). Any other value is `bad json`.

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

A print body may carry `copies`, 1 to 99, default 1. 0 or a count above 99 is `BadCopies`; a value that is not a whole number from 0 to 65535 is `bad json`. A D11, D110 or D110_M prints the copies itself: on protocol 4 the job has that many pages and the page that many copies, and below it `PrintQuantity` is set to the count. A B-series sequence has no count, so the job is sent once per copy. The `print` trace line names the count.

`POST /api/printer/clock` takes `{"conn", "addr", "year", "month", "day", "hour", "minute", "second"}` and sets the printer's clock, which its date button prints and which counts from 1970 until something sets it. The page sends its own local time, because the browser knows the time zone of the machine it runs on and the printer keeps none. The packet is `PrinterConfig2` (`0x07`) as the protocol notes draw it: `01` (set), the year as two bytes, then month, day, hour, minute and second. The answer echoes the first byte and then gives the result: a D110_M answers `01 01`, done. Upstream's library puts an item byte `08` in front, which a D110_M refuses with `08 00`, so that form is only tried when the first is refused. All eight fields are required, and a missing one is `bad json`. An empty `addr` is `no address`, a year outside 2000 to 2099 or another field out of range is `BadTime`, a printer that cannot be opened answers with the transport's error name, and a printer that refuses both forms is `ClockRefused`. Success is `{"ok":true}`. The `clock` trace line says what was set and what the printer answered.

`POST /api/printer/info` takes `{"conn", "addr"}` and asks the printer what it is, reading and changing nothing: `PrinterInfo` (`0x40`) for the model id, the firmware version and the hardware version ([printer.md](printer.md#wire)). The answer, from a D110_M:

```json
{"model_id":2320,"model":"d110_m","firmware":"4.30","hardware":"4.01"}
```

`model` is the model the id names, null for one this bench does not print to. A field the printer does not answer is null. An empty `addr` is `no address`, and a printer that cannot be opened answers with the transport's error name. The `info` trace line says what the printer answered.

The render answer and the print are always the roll: width across the head, height along the tape. Neither route turns the page. `rotate` is still accepted in a body for older callers and does nothing; the CLI's `--rotate` turns a raw PGM page before sending it, which is a different path and the only place a page is turned.

The editor's **Orientation** buttons are not this either. They turn the picture in the window for display and are never sent: the width and height the server sees are the page's own whichever way the editor is showing it.

## The roll

`POST /api/label/roll` reads the roll's barcode from the printer's tag and answers the roll's size in millimetres and in dots — the whole label, which is what the Width and Height fields are set to. A print leaves the model's page margin off the end ([printer.md](printer.md#raster)), so a 12×40 roll answers 96×320, the editor lays out on 96×320, and 304 rows are printed. It carries the preset id when this bench has a row for it.

The body is `{"conn": "usb"|"bluetooth", "addr": "...", "model": "b21"}`; `model` defaults to `b21`, and `allow_cloud` is below. The answer:

```json
{"barcode":"01222281","width_mm":12,"height_mm":40,"source":"catalogue","width":96,"height":320,"id":"12x40","labels_total":186,"labels_used":35}
```

`labels_total` and `labels_used` are what the roll's tag says: how many labels the roll holds, and how many the printer has used. The printer adds one to the tag for every label it feeds, test prints and labels fed again included, and refuses a roll whose count is used up, whatever is left on it. They are left out when the tag's answer stops short of them.

`id` is the size's entry in `/api/label/sizes`, or null when this bench has no row for it. An empty `addr` is `no address`, an unknown model is `unknown model`, a printer with no tag on its roll is `no roll`, a barcode the catalogue does not hold is `unknown roll`, and a failed cloud lookup is `roll lookup failed`; a printer that cannot be opened or read answers with the error'''s name.

The barcode is resolved from the catalogue compiled into the binary, which holds every roll the vendor lists, found by its barcode or by any of the other codes the vendor gives the same roll, since a tag may carry any of them, so the answer needs no network and no configuration. The body may set `"allow_cloud": true` to permit a second attempt against the vendor's cloud for a barcode the catalogue does not carry; without it such a barcode is `unknown roll`. `"from_cloud": true` asks the cloud first, even for a barcode the catalogue carries, which is the editor's **Fetch** and the way round a roll the catalogue lists wrong. The vendor lists some rolls length first, `041025002` as 40x12 for a 12 mm roll of 40 mm labels; a size wider than the widest roll the model takes, whose length would fit, is turned to face the head, and the trace says so. A cloud answer for a barcode the compiled-in catalogue lacks is saved to `.niimbench.rolls.json` in the working directory, written aside and renamed over the old file, and from then on that barcode is answered from there, with no cloud asked; **Fetch** still asks the cloud, and replaces the saved copy. [../labels/README.md](../labels/README.md#regenerating) says how saved rolls are added to the catalogue itself. The cloud's size is the template's own, the top-level `data.width` and `data.height`, rounded to whole millimetres; the elements laid out on the template carry sizes of their own. The answer's `source` says which resolved it, `catalogue`, `saved` or `cloud`, and the editor shows `(saved)` or `(cloud)` after the size. The editor picks a printer and takes the canvas from this answer, so the roll sets the size rather than the person. The catalogue itself is [../labels/README.md](../labels/README.md).

## Failures

`render` and `print` answer a failure in the same shape as a success, including the label size the body asked for, so the page can draw an empty label instead of keeping a stale preview. A body whose size cannot be read at all gets the default, 384×96, and the page keeps its own **Width** and **Height** whatever the answer says:

```json
{ "error": "UnknownSource", "width": 384, "height": 96 }
```

A print the printer refused is `PrinterRefused`, with a `reason` in the printer's own words when it gave one, such as `{"error":"PrinterRefused","reason":"WriteRfidFail",…}`; the names are [printer.md](printer.md#refusals).

`NothingToPrint` is a `render` body with no fields, no background, and no `pixels_b64`. `UnknownSource` is a 404. Everything else is 400. The `sources` routes answer `{"error":"..."}` only.

A body larger than 4 MiB answers `413` with `{"error":"body: StreamTooLong"}`, rather than dropping the connection. A request that sends `Expect: 100-continue`, as curl does with any body over 1 MB, gets `100 Continue` before its body is read.

After a successful print the context emits `print/done`.

## Metrics

`GET /api/label/metrics` returns every embedded font's measuring table, so the boxes the editor draws, and resizes live while a corner is dragged, match the ink without asking the server on every pointer move:

```json
{
  "default": "fira-sans-bold",
  "max_size": 1024,
  "fonts": [
    { "id": "fira-sans", "name": "Fira Sans", "line_units": 1200, "missing": 666, "advances": [[32, 268, 241, 390]] }
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
{"fields":[{"origin":"record","text":"NB-1","x":0},{"origin":"literal","text":"hand written","x":0},{"origin":"missing-key","x":0}]}
```

`origin` is one of:

| Value | Meaning |
|---|---|
| `literal` | The field has no `key`, so it draws its own `text` |
| `record` | The key resolved in `source`; `text` is what the renderer will draw |
| `missing-key` | `source` is installed but carries no such key |
| `unknown-source` | `source` is empty or not installed |
| `structured` | The value is an object or array, which draws as empty text |
| `dynamic` | The record has no value here that can be reported as plain text |

Every entry also carries `x`, the left edge of the block as the renderer places it after its alignment, negative for a centred or right-aligned block that starts left of the label, and `text` for a literal or a resolved record. The editor draws its selection box at that `x` and sizes it from that `text`, so the box matches the ink even when `center` or `right` moved the line.

A field whose `font` the build does not carry is refused the way `render` refuses it: 400 with `{"error":"UnknownFont","width":0,"height":0}`. Resolving the value server-side keeps one implementation of `label.resolve`.

## Listening

The listener reads a request body only when the head announced a `content-length`. A method that may carry a body does not have to, and reading to end-of-stream on a body that never arrives would block the single-threaded accept loop. For the same reason a connection that sends nothing for two seconds is closed unanswered: a browser opens spare connections ahead of need, and one held open idle stopped every other request and the idle stop.
