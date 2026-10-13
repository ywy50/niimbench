# Testing

`zig build test` runs the module tests and the executable tests.

What the tests lock in:

- Packet bytes round-trip, and a flipped checksum is rejected.
- Black grayscale packs to burned bits, white packs to zeros, and a clockwise turn matches the paper rotation used by niimprint's Pillow call.
- A plugin with a missing coeffect stays inactive, then applies when the service appears.
- Disposing the providing fiber removes the service, the dependent service, and the event listener.
- Duplicate mount ids fail.
- The patch parser keeps `inject` order.
- Bluetooth addresses are stored in the BlueZ `str2ba` byte order.
- The editor route is gone after its fiber is disposed.
- `/api/health` without a token is unauthorized.
- A scripted transport records the print command sequence: density, label type, start, page, dimension, image row, end page, end print.
- A binary PGM header parses.

The HTTP listener and the real serial port are not part of `zig build test`. Print against hardware with `zig build run -- print ...`.
