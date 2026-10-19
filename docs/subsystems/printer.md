# Printer

The printer subsystem is the codec, the raster, the client, the two openers, and the two finders. Every step that reaches a printer or a roll is recorded in the [trace](trace.md), which is what makes a job that failed on the wire readable afterwards. The `printer` plugin publishes an empty `PrinterService` so other plugins can `inject` it. `transports` publishes the registry. `devices` publishes the scan registry. `serial` and `bluetooth` install an opener and a finder each, and remove both on dispose.

## Wire

Requests use the packet codes in the [protocol reference](../manuals/upstream/interfacing/proto.md). Responses are `request + 1`, except density, label type, print status, `PrintClear` and `PrinterStatusData`, which answer at `request + 16`, and the finder's `PrinterInfo` probe, which answers `0x48`, `request + 8`. An image row is type `0x85` and expects no response. A run of identical rows goes as one `0x85` whose last header byte is the repeat count, and a run of blank rows as one `0x84` (`PrintEmptyRow`: row number, count), each run up to 255 rows. Every packet waits for its acknowledgement on Bluetooth, about 25 ms, so a mostly white 304-row label went from 304 packets and 7 s to a few dozen. Packet type `219` is a refusal. Packet type `0` is unsupported.

A D11 or D110 job first asks the printer's protocol version, the way the official clients do: `Connect` (`0xC1`, the one request with a `0x03` prefix byte) answers `0xC2` with 3 for version 3 and up, and then `PrinterStatusData` (`0xA5`, answered `0xB5`) carries the version in data bytes 11 and 12 (`n = b11*100 + b12`: 300 or 301 is version 4). On protocol 4 or newer the job sends upstream's `D110M_V4` sequence: label type, density, a 9-byte `PrintStart` whose first word is the job's page count, a `PrintStatus` nothing waits for, no `PageStart`, and a 13-byte `SetPageSize` whose third word is the page's copy count, both the print body's `copies`; after `PrintEnd` it sends a heartbeat nothing waits for. Below protocol 4 the job keeps the older D110 sequence with `PrintClear` (`0x20`, answered `0x30`) before `PageStart` and `PrintQuantity` (`0x15`) after `SetPageSize`, set to the copy count. A probe that fails or gets another answer counts as version 0, so that printer keeps the older sequence. A D110_M answers protocol 4 (`n = 301`). Sent the older sequence, it printed a label twice, both copies whole, now and then, and still did with `PrintQuantity` set to 1. The B-series send neither the probe nor these commands. A status that shows the counter past the last copy while the head prints again is a copy the job did not ask for, and the trace says `page N done and another copy started`.

`PrintEnd` goes out after `PrintStatus` (`0xA3`) shows the job printed. The job's target is its copy count on the D-series and 1 on the B-series, which is sent once per copy. The page counter has to move by the target from the value read after `PageEnd`, or the print progress has to leave 100 and come back with the counter at the target and print and feed both at 100. The polls allowed are 25 times the target, 200 ms apart. A ten-byte `PrintStatus` answer whose byte 6 is not 0, a cover, paper or battery fault, is `error.PrinterRefused`. A counter that stays put while progress stays at 100 is `error.PrintSkipped`. Progress that leaves 100 and does not come back finished is `error.PrintDidNotFinish`. `PrintEnd` is still sent either way, because the image is already on the wire. A printer that answers `PrintStatus` with packet type `0` is finished by polling `PrintEnd` instead.

## Raster

Input is grayscale, row-major, `0` black, `255` white. A pixel below 128 becomes bit 1, a burned dot, most significant bit first.

`SetPageSize` (`0x13`) carries `RR RR CC CC`: the row count — the page's length down the tape — first, then the column count across the head. Putting the width in the row slot tells the printer the page is as many rows long as the head is wide: on a 12×40 roll it prints about 12 mm and drops the rest of the image, which looks like a page that stops short rather than like a size error.

A print stops short of the label's full length by the model's page margin, because the gap sensor sits past the last row of the head and needs white space to find the next gap in. Without that margin the printer keeps feeding until it ejects the following label blank. The editor lays out on the whole label, so its centre is the paper's centre, and `printJob` leaves the margin's rows off the end of the composed page when it prints; the preview hatches them. A 12×40 label is laid out as 96×320 and printed as its first 304 rows. Laying out on the 304 printed rows instead put everything centred 8 dots, 1 mm, toward the end of the label that leaves the printer first. A body that carries raw `pixels_b64` is the page itself and is printed as sent.

## Models

| Model | Max width | Max density | Page margin | Copies |
|---|---|---|---|---|
| b1, b21 | 384 | 5 | 0 | the job once per copy |
| b18 | 384 | 3 | 0 | the job once per copy |
| d11, d110 | 96 | 3 | 16 dots (2 mm) | the printer's own count |

Widths above the head size are `error.TooWide` before any byte is written. A density above the model's maximum is lowered to it, and 0 is `error.BadDensity`. The copies column is `raster.Model.setsCopies`: a D-series printer is told the count, and a B-series sequence has none, so its job is sent once per copy. The D-series margin was measured on a D110_M with a 12×40 roll: a 304-dot page printed and a 308-dot page fed the next label out blank, so a full height 12×40 canvas, which is 96×320, prints as 96×304.

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

On macOS the Bluetooth finder asks CoreBluetooth instead, through the Objective-C runtime (`src/corebluetooth.zig`). `{"discover":true}` listens for advertisements for the same two seconds and keeps the same names. The plain scan is the Niimbot printers already connected to the Mac, the nearest thing macOS has to a paired list. macOS shows a program no MAC, so a printer's address there is the UUID the Mac gives it.

## Transports

USB opens the given path at 115200 8N1 and uses `VMIN=0`, `VTIME=5` so a read returns after half a second of silence. The termios bits are set with `TCGETS` / `TCSETS`, not libc.

Bluetooth opens the print channel of a BLE printer over the system bus: `Device1.Connect`, an `AddMatch` rule for the characteristic's `PropertiesChanged` signals, `GattCharacteristic1.StartNotify`, then `WriteValue` for each frame the client sends. The characteristic is looked up by uuid rather than by path. BlueZ announces every notification as one `PropertiesChanged` signal, even when the value has not changed, so a read waits on the bus socket and takes each answer the moment it arrives. A signal that lands while a call waits for its own reply is kept for the reader, not dropped. Without the rule no signal was delivered, and reading BlueZ's cached `Value` instead could not tell a second, identical answer from the first: every repeated status waited out the client's 3 s timeout. When no signal comes within half a second, the read falls back to the cached `Value` once, skipping a value equal to the last one handed over. `src/ble.zig` is the transport and the GATT client lives in `src/dbus.zig`.

On macOS the same channel opens through CoreBluetooth: the peripheral is looked up by its UUID, connected, the print characteristic found by uuid and subscribed to, and each frame is a write with a response. Notifications arrive as delegate calls and are buffered, so a read returns as soon as an answer is there instead of polling. The radio's state comes first, and `BluetoothOff`, `BluetoothNotAllowed` (the terminal was refused Bluetooth) or `BluetoothUnsupported` is the print's error. A UUID this Mac has not seen is `PrinterNotSeen`, a peripheral without the print service or characteristic is `PrintCharacteristicMissing`, and a notify or write the printer refuses is `NotifyRefused` or `WriteRefused`. USB is Linux-only: on macOS the `serial` plugin installs nothing, and a USB print answers `UsbUnavailable`.

A BLE-only model such as the D110_M has no Classic radio: it does not advertise the Serial Port Profile, sets `BR/EDR Not Supported`, and answers an RFCOMM connect with `EHOSTDOWN`. So there is no RFCOMM opener; a Bluetooth address is a BLE address. An empty address is rejected. Nothing picks a port by itself: a caller passes the tty path or a MAC (a UUID on macOS), and the editor gets both from the printer list `/api/devices` builds.
