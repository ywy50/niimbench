# Printer

The printer subsystem is the codec, the raster, the client, and the two openers. The `printer` plugin publishes an empty `PrinterService` so other plugins can `inject` it. `transports` publishes the registry. `serial` and `bluetooth` install openers into that registry and remove them on dispose.

## Wire

Requests use the niimprint codes. Responses are `request + 1`, except density and label type, which use `request + 16`. An image row is type `0x85` and expects no response. Packet type `219` is a refusal. Packet type `0` is unsupported.

## Raster

Input is grayscale, row-major, `0` black, `255` white. A pixel below 128 becomes bit 1, most significant bit first, matching `ImageOps.invert` followed by mode `"1"`.

`set_dimension` sends height as the first 16-bit word and width as the second.

## Models

| Model | Max width | Max density |
|---|---|---|
| b1, b21 | 384 | 5 |
| b18 | 384 | 3 |
| d11, d110 | 96 | 3 |

Widths above the head size are `error.TooWide` before any byte is written.

## Transports

USB opens the given path at 115200 8N1 and uses `VMIN=0`, `VTIME=5` so a read returns after half a second of silence. The termios bits are set with `TCGETS` / `TCSETS`, not libc.

Bluetooth opens an `AF_BLUETOOTH` `BTPROTO_RFCOMM` socket and connects to channel 1. The six address bytes are reversed, which is what BlueZ `str2ba` does. An empty address is rejected. niimprint's `"auto"` serial scan is not implemented; pass the tty path or pick one from `/api/ports`.
