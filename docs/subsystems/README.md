# Subsystems

One reference page per subsystem. [architecture.md](../architecture.md) is the map across them. A page here owns the types, routes, and lifetimes for its subject.

| Page | Owns |
|---|---|
| [printer.md](printer.md) | Packet codes, raster, models, label rolls, the USB and Bluetooth openers |
| [http.md](http.md) | Routes, session token, label body, render and print failures, metrics, field tracking |
| [sources.md](sources.md) | Named JSON records, plugin lifetime versus runtime lifetime |
| [trace.md](trace.md) | The in-memory log, its three routes, and the report harness |
| [text.md](text.md) | Fonts, what `size` means, measuring a line, filling glyph outlines |

A new subsystem page starts from [../templates/reference.md](../templates/reference.md) and gets a row in this table and in [../README.md](../README.md).
