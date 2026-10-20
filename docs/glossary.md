# Glossary

**Context.** The service map, listener list, and fiber list for one process.

**Plugin.** A named `apply` function plus the service keys it requires.

**Fiber.** One mount of a plugin. Disposing it runs that mount's inverses.

**Service.** A pointer published under a string key, for example `"printer"` or `"http"`.

**Effect.** A registration paired with a function that undoes it.

**Coeffect.** A service key in `inject`. The fiber applies only while every key is present.

**Source.** A named JSON record a render can draw a field's `key` from. `json-source` publishes `"example"`; `POST /api/sources` installs one that lasts until the `http` fiber drops or `DELETE /api/sources/<name>` removes it.

**Origin.** What a field's text comes from: its own `literal`, or a `record` key. `/api/label/track` reports it.

**Layout.** The label body plus the printer fields as JSON. Save layout writes one, Load layout reads one back; the background image is not part of it.

**Field.** A block of text on a label: literal `text`, or `key` into a source, at `x`, `y`, in a `font`, with a `size` in dots that is its line height.

**Font.** One of the typefaces embedded in the binary, named by an id such as `dejavu-sans`. The list and licences are [../src/fonts/README.md](../src/fonts/README.md); how text is drawn is [subsystems/text.md](subsystems/text.md).

**Metric.** A font's advance table, published for every font at `/api/label/metrics`. The editor sizes its field boxes with the numbers `label.zig` renders with.

**Block.** The lines a field draws. A newline in the text starts the next one, `size` dots down.

**Alignment.** What a field's `x` refers to: the left edge, the centre, or the right edge of the line. The line is measured after its `key` resolves.

**Clipped.** A field whose text would cross any edge of the printable area: the label's sides, or on the D-series the unprinted strip at its end. The renderer draws the part that fits and the editor marks the row.

**Transport.** An open USB serial port or BLE print channel with `read`, `write`, and `close`.

**Finder.** A transport's scan for printers, the counterpart of its opener. `serial` and `bluetooth` each install one into the `devices` registry; on macOS `serial` installs nothing.

**Found device.** One printer a scan confirmed: its connection and address, the model its head or name implies, and its model id. The editor's **Found Niimbot devices** list is `GET /api/devices`.

**Scan.** One run of every finder. `POST /api/devices/scan` starts it; `{"discover":true}` adds a Bluetooth inquiry, which is the only part that reaches a printer that was never paired.

**Token.** 16 random bytes, printed as hex, required on every HTTP request for that process. The browser exchanges `?token=` for an `HttpOnly` cookie named `niimbench-<port>` and then requests `/` without the query.
