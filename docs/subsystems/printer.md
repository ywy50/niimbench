# Printer

The printer subsystem is the codec, the raster, the client, the two openers, and the two finders. Every step that reaches a printer or a roll is recorded in the [trace](trace.md), which is what makes a job that failed on the wire readable afterwards. The `printer` plugin publishes an empty `PrinterService` so other plugins can `inject` it. `transports` publishes the registry. `devices` publishes the scan registry. `serial` and `bluetooth` install an opener and a finder each, and remove both on dispose.

## Wire

Requests use the packet codes in the [protocol reference](../manuals/upstream/interfacing/proto.md). Responses are `request + 1`, except density and label type, which use `request + 16`. An image row is type `0x85` and expects no response. Packet type `219` is a refusal. Packet type `0` is unsupported.

## Raster

Input is grayscale, row-major, `0` black, `255` white. A pixel below 128 becomes bit 1, a burned dot, most significant bit first.

`SetPageSize` (`0x13`) carries `RR RR CC CC`: the row count — the page's length down the tape — first, then the column count across the head. Putting the width in the row slot tells the printer the page is as many rows long as the head is wide: on a 12×40 roll it prints about 12 mm and drops the rest of the image, which looks like a page that stops short rather than like a size error.

A page also stops short of the roll's full height by the model's page margin, because the gap sensor sits past the last row of the head and needs white space to find the next gap in. Without that margin the printer keeps feeding until it ejects the following label blank. The margin is taken off in one place — where a roll's size is resolved for a caller — so `compose` prints exactly the page it is asked for. Keeping the roll's full height and the margin apart matters: a 12×40 roll is 320 dots long, the page on it is 304, and a caller that lays out against 320 builds a frame taller than the picture and its boxes fall outside it.

## Models

| Model | Max width | Max density | Page margin |
|---|---|---|---|
| b1, b21 | 384 | 5 | 0 |
| b18 | 384 | 3 | 0 |
| d11, d110 | 96 | 3 | 16 dots (2 mm) |

Widths above the head size are `error.TooWide` before any byte is written. The D-series margin was measured on a D110_M with a 12×40 roll: a 304-dot page printed and a 308-dot page fed the next label out blank, so a full height 12×40 canvas, which is 96×320, prints as 96×304.

## Label stock

These heads are 203 dpi, 8 dots per millimetre. The editor's label menu is `GET /api/label/sizes`, and the rolls the vendor catalogues are [../labels/README.md](../labels/README.md). Picking a roll sets the canvas to millimetres times 8, and the width stops at `maxWidth`.

| Models | Rolls | In the box |
|---|---|---|
| b1, b21 | Direct thermal, 20–50 mm across the head. Same rolls. | 50×30 mm, which is 384×240 because 50 mm is 400 dots and the head is 384 |
| d11, d110 | Direct thermal, 12–15 mm across the head. Same rolls. The printable width is 12 mm. | D11 is 12×40 mm (96×320). D110 is 15×30 mm, which clamps to 96×240 |
| b18 | Thermal-transfer rolls, 10–14 mm. Not the D11 rolls. The manual calls the print width 12 mm. | 14×50 mm is 112×400, which is under the 384-dot protocol limit this model shares with B21 |

A round roll uses a square of its diameter. Cable flags and continuous tape are not in the menu.

## Discovery

`devices` publishes a `discovery.Registry` holding the finders and the last scan. `serial` and `bluetooth` install their finder next to their opener, so a disposed transport takes its finder out of the answer as well. The editor's printer list is `GET /api/devices`; `POST /api/devices/scan` runs the scan and is what fills it.

The USB finder asks every `ttyACM*` and `ttyUSB*` under `/dev` for `PrinterInfo` key `0x08`, the model id, and reports the port only when something answers, so another serial device is not offered as a printer. A probe reads with `VTIME=1`, so a port that is not a printer costs a tenth of a second. The port's USB product string names the device when sysfs has one.

| Model id | Model |
|---|---|
| 768, 769, 771, 775, 776, 777 | b21 |
| 4096, 4098 | b1 |
| 3584, 3585 | b18 |
| 512, 513, 514 | d11 |
| 2304, 2305, 2320 | d110 |

These are the 203 dpi heads. A model id outside the table, such as one from a 300 dpi Pro, is reported with no model, and picking that device leaves the model field alone.

The Bluetooth finder asks BlueZ for its managed objects over the system bus. `src/dbus.zig` is the client: it authenticates, calls `ObjectManager.GetManagedObjects`, and reads the `a{oa{sa{sv}}}` answer. It keeps `org.bluez.Device1` entries whose name carries `niimbot` or a whole model word, and a name with `pro` in it resolves to no model. A name is the only model signal Bluetooth offers without connecting, and a device name such as `Speaker` that advertises the serial profile too is not a printer.

The scan body `{"discover":true}` starts an inquiry on the first adapter, waits two seconds, and asks again, so a printer that is on but has never been paired is seen. The plain scan is the set BlueZ already knows: printers paired with this machine, or seen by an earlier inquiry.

## Transports

USB opens the given path at 115200 8N1 and uses `VMIN=0`, `VTIME=5` so a read returns after half a second of silence. The termios bits are set with `TCGETS` / `TCSETS`, not libc.

Bluetooth opens the print channel of a BLE printer over the system bus: `Device1.Connect`, `GattCharacteristic1.StartNotify`, then `WriteValue` for each frame the client sends. The characteristic is looked up by uuid rather than by path. Reads are polls of the characteristic's `Value` property, which is where BlueZ caches a notification, so a frame that the printer has not answered yet reads as nothing and the client's own retry loop covers it. `src/ble.zig` is the transport and the GATT client lives in `src/dbus.zig`.

A BLE-only model such as the D110_M has no Classic radio: it does not advertise the Serial Port Profile, sets `BR/EDR Not Supported`, and answers an RFCOMM connect with `EHOSTDOWN`. So there is no RFCOMM opener; a Bluetooth address is a BLE address. An empty address is rejected. Nothing picks a port by itself: a caller passes the tty path or a MAC, and the editor gets both from the printer list `/api/devices` builds.
