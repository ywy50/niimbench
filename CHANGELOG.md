# Changelog

Notable changes to niimbench are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each section matches
a release tag, and its version is the one `build.zig.zon` declares, which
`niimbench --version` reports.

niimbench is 0.x: a minor release (`0.Y.0`) may change the editor, the CLI or
the HTTP routes; a patch release is expected not to. Releases are tag-driven,
and [docs/cookbook/releasing.md](docs/cookbook/releasing.md) is the procedure.

## [Unreleased]

### Changed

- On a D11 or D110 the editor lays out on the whole label, 96×320 for a 12×40 roll, and hatches the last 2 mm that the printer leaves blank for its gap sensor. Width and Height show the whole label. A print sends all but those rows, as before.

### Fixed

- Centred text on a D11 or D110 printed 1 mm off centre, toward the end of the label that leaves the printer first. The editor laid out on the 304 printed rows of a 320-dot label, so its centre was 8 dots short of the paper's. Center, Fit and new text now centre on the whole label, on every roll size.
- Picking a roll from the **Label** menu and reading it from the printer gave different heights on the D-series, 320 and 304 for a 12×40. Both now give the whole label, and a print from either sends the same 304 rows.

## [0.4.0] - 2026-10-19

### Changed

- A text row names its controls: **Font**, **Size**, **X**, **Y** and **Angle**, where four bare numbers stood. The text box resizes in width as well as height, up to the row's width, and no longer shows a scrollbar over its one line.
- A text row lays out by its panel's width: in a narrow panel or on a phone the text, the font and the four numbers each take a full line, and the buttons wrap under them.

### Fixed

- Between 52rem and 60rem of window width, every text row was forced 40rem wide and its last buttons were cut off at the panel's edge.
- On a phone the whole page scrolled sideways: the board's 23 column gaps alone were wider than the screen. A phone gets one column.
- A drag whose release the canvas never heard — let go outside the window, or a right-click whose menu took it — stayed live, and every later pass of the pointer over the preview moved the field. The preview renders on the drop, so it kept showing the text where it was, and the label printed wherever the pointer had crossed the canvas on its way to **Print**. A move with no button held now ends the drag, and only the primary button starts one.
- The trace said how many fields a print had but not where they were. Each field now has a `print` line with its position, size and turn.

## [0.3.0] - 2026-10-19

### Added

- `make trace` prints the running server's log. The server writes its URL, token included, to `.niimbench.token` at startup, readable only by its owner, so the log no longer needs the token copied from the terminal.

### Changed

- The font menu lists Fira Sans and Fira Sans Bold first. A field that names no font, and a new row in the editor, is drawn in Fira Sans Bold.

### Fixed

- The `http` plugin's `inject` declaration lists only what its `apply` requires. `trace` was declared required although every route treats it as optional, so a context without the trace plugin could not boot the editor, and withdrawing the plugin at runtime dropped the whole `http` fiber.
- A scan whose finder failed answered as if it had run clean. The answer now keeps the finding it made anyway and names the failure — `"scan_error":"bluetooth:BusUnavailable"` — and the scan's trace line says the same. A Bluetooth inquiry that cannot start is reported the same way, with the passive answer kept.
- A request body larger than the server takes was dropped with no answer. It now receives `413` and an error name.
- A request carrying `Expect: 100-continue`, which curl sends with any body over 1 MB, crashed the server. It is now answered `100 Continue` and served.
- A roll read that failed — the barcode read, or the cloud lookup — reached no record at all. It now lands in the trace with the device and the cause, and a print failure names the connection, address and model it was aimed at.
- A label size past the printer protocol's 16-bit limit could overflow while it was checked, which in a release build stops the server. It is refused as `BadSize` before anything multiplies it.
- A print the printer never counted is `PrintSkipped` instead of `printed`. The job ends after `PrintStatus` shows the page; an idle `PrintEnd` used to close the link and report success while the label stayed in the printer.
- A print job left nothing in the trace between `print` and `sent`, so a blank page and a printed one read the same. The `printer` lines now record what each command answered, every `PrintStatus` reading, and how `PrintEnd` closed the job.

## [0.2.0] - 2026-10-14

### Added

- A **Smooth** toggle under the preview rounds the enlarged dots into each
  other instead of drawing each as a square, roughly how they look on paper.
  The dots, and what prints, are the same either way; the choice is remembered
  in this browser.
- More than one picture on a label. **Add images** takes one file or several,
  each goes on top of the others, a press takes the topmost, and the Image
  panel's controls act on the picture last clicked or added.
- A **Center** button on each text row puts the field back in the middle of
  the label, upright in the view, at the size it has.

### Changed

- The row under the preview keeps the hint and its toggles on one line and
  the view's numbers on a small line of their own, instead of running into
  each other.
- The Label and printer panel opens with the printer: its status and last
  job, the found devices, then connection and address, then the cloud opt-in,
  which now reads "Ask the cloud for unknown label rolls" on one line. The
  label's model, size, density and orientation follow.

### Removed

- The Left, Center and Right menu on each text row. New fields are centred; a
  layout saved with another alignment still loads and prints as saved.

### Fixed

- A picture added in the Vertical view lands on the label, upright. It was
  centred by the view's shape, which put it off the narrow roll until a switch
  to Horizontal re-placed it.
- A picture's round grip is drawn where a press finds it, and stays on the
  label. In Vertical it was drawn on the opposite side, and a picture fitted
  to the label had its grip beyond the edge, so it could not be turned by
  hand.
- **Copy** keeps the field's font.
- Dragging a field's round anchor in the Vertical view no longer flips the
  text upside down on the first move: the drag added the view's quarter turn
  the wrong way round.
- The preview's boxes, handles, guides and picture outline are sharp. They
  were drawn into the label's own dots and enlarged with them, so a one-dot
  line was several screen pixels of blur; they are now a layer of their own at
  the screen's resolution, one size on screen at any zoom.
- Turned text prints with solid strokes. A field at an angle was drawn upright
  and its dots then turned, which put every stroke on the dots twice and left
  thin ones stepped and broken; each letter's outline is now turned before it
  is filled.

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

[Unreleased]: https://github.com/ywy50/niimbench/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/ywy50/niimbench/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ywy50/niimbench/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ywy50/niimbench/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ywy50/niimbench/releases/tag/v0.1.0
