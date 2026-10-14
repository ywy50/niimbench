# Changelog

Notable changes to niimbench are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each section matches
a release tag, and its version is the one `build.zig.zon` declares, which
`niimbench --version` reports.

niimbench is 0.x: a minor release (`0.Y.0`) may change the editor, the CLI or
the HTTP routes; a patch release is expected not to. Releases are tag-driven,
and [docs/cookbook/releasing.md](docs/cookbook/releasing.md) is the procedure.

## [Unreleased]

## [0.1.0] - 2026-10-14

The first public release.

### Added

- A local editor, served on `127.0.0.1` behind a per-session token: lay out
  text and a picture on a label and see the grayscale the print head will get.
  The preview and the print share one drawing path on the server.
- Text fields with a font, a size in dots, an alignment, a position and an
  angle. Drag a field to move it, a corner to resize it, the round handle to
  turn it; fields that would run off the label are marked clipped, and
  **Fit** and **Wrap** bring them back.
- Fifteen embedded free fonts, drawn by niimbench's own TrueType rasteriser,
  so a print never depends on what is installed.
- Pictures reduced to one ink at a threshold you choose, then moved, scaled and
  turned on the label.
- Printing to the B1, B18, B21, D11 and D110 over USB serial, and over
  Bluetooth Low Energy through BlueZ.
- A printer scan of the serial ports and BlueZ that fills in the connection,
  the address and the model, and reads the loaded roll's size from its tag and
  the compiled-in label catalogue.
- Horizontal and vertical views, undo and redo, and layouts saved and loaded as
  JSON.
- A board of panels you drag and resize, kept per browser, with the label's
  actions on the page header.
- `niimbench print` for a binary PGM from the command line, and
  `niimbench --version`.
- An in-process trace of what the server and the page did, readable at
  `GET /api/trace`.
- `make test`, which drives the page in a headless browser, and `make drive`
  for scripted looks at it; no server a test starts can outlive the run.

[Unreleased]: https://github.com/ywy50/niimbench/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ywy50/niimbench/releases/tag/v0.1.0
