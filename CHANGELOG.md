# Changelog

Notable changes to niimbench are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Each section matches
a release tag, and its version is the one `build.zig.zon` declares, which
`niimbench --version` reports.

niimbench is 0.x: a minor release (`0.Y.0`) may change the editor, the CLI or
the HTTP routes; a patch release is expected not to. Releases are tag-driven,
and [docs/cookbook/releasing.md](docs/cookbook/releasing.md) is the procedure.

## [Unreleased]

### Added

- The printer line says how many labels the roll's tag has left, such as `151 of 186 labels left`, once the roll is read, and counts down as you print. The printer refuses a roll whose count is used up, even with labels left on it. `POST /api/label/roll` answers `labels_total` and `labels_used`.
- A refused print says why, in the printer's own words: `PrinterRefused: WriteRfidFail` where it said `PrinterRefused`. `POST /api/print` adds the name as `reason`.

### Fixed

- A roll whose tag UUID begins with a 0 byte read as no roll.
- A D110_M's status code at the end of a page was not looked at. A tag it could not write, the first sign of a used-up roll, now shows in the trace.

## [0.9.0] - 2026-10-27

### Changed

- **Copies** goes back to 1 after a print that worked, so a count meant for one job is not printed again by the next. After a print that failed it keeps its number, for a retry.

## [0.8.2] - 2026-10-22

### Fixed

- The Mac app's launcher, and not only the server app inside it, now says in its `Info.plist` why niimbench uses Bluetooth. macOS ends a process that reaches for Bluetooth when the app it counts that process under leaves this out. On a Mac, the server was gone after the page's first printer scan: the page said `scan failed`, and a reload found nothing listening.
- CI now scans from the running Mac app, both the page's quick scan and **Find nearby**. It checks the server is still there after each, and prints the crash report macOS wrote when it is not.

## [0.8.1] - 2026-10-22

### Fixed

- On a Mac, **Find nearby** stopped niimbench as soon as it heard a Bluetooth device that names its services, which most do, and the page said only `scan failed`. The services an advertisement names are a list of UUIDs, and niimbench asked each for a UUID of its own, a message a UUID does not answer; the exception that raised on CoreBluetooth's thread ended the process. GitHub's Macs, which run the checks, have no Bluetooth radio and never hear one, so a check now hands the scan an advertisement as CoreBluetooth does.

## [0.8.0] - 2026-10-22

### Added

- **A Mac app.** `niimbench-macos.zip` holds `niimbench.app`, for macOS 13 or later on Apple silicon and Intel. Opening it opens the editor in the browser, opening it again while it runs opens its page, and the page's **Quit niimbench…** stops it. It is signed ad hoc and not notarized, so its first open needs your say-so; the README says how.
- **`.deb` and `.rpm` packages** for x86_64 and arm64 Linux. They install `niimbench` and a desktop menu entry that starts it with `--app`, recommend BlueZ and `xdg-utils`, and depend on nothing. The tarballs carry the same menu entry and icons under `share/`.
- **An Arch package**, `niimbench-bin`. Each release writes its `PKGBUILD` from the tarballs' checksums, checks it on Arch, and puts it on the release, where `makepkg -si` installs it. It goes to the AUR too once the repository has an AUR key ([docs/cookbook/releasing.md](docs/cookbook/releasing.md#the-aur-package)).
- `--app` serves from a per-user folder, `~/Library/Application Support/niimbench` on a Mac and `~/.local/state/niimbench` elsewhere, for a start from an app or a desktop menu that has no folder of its own.

## [0.7.0] - 2026-10-20

### Added

- A **d110_m** model, for the D110_M: the same head, rolls and print sequence as the D110, with density 1 to 5 where the D110 takes 1 to 3. A scan names it by its model id, 2320, or by its Bluetooth name, `D110_M-…`; it used to be found as a d110 and held to 3.
- **Quit niimbench…**, in a menu on the **niimbench** name at the top left, stops the server after asking. **Reset panels** moved into the same menu, so the header's right side holds only what printing needs.
- The server stops by itself when no page has been open for 30 minutes. `--idle-minutes N` changes the time, and 0 keeps it running.

### Changed

- **Undo** takes back a typed word at once. Typing in one box, **Width** and **Height** included, is one change until you pause for a second or go to another control; it used to be one change per letter.
- Starting niimbench while it already runs from the same folder opens the running one in the browser and exits, instead of refusing. With `--no-open` it still refuses and names the running process.
- The **Sync clock** tooltip says it sets the printer to this computer's local date and time, which is what the date button prints.
- `make help` lists `BROWSER`, the Chromium-family browser the browser checks use.

### Fixed

- Pressing Enter in any number or text box, a row's **X** or the **Address** among them, printed the label. Enter now only confirms the box; **Print** and Ctrl+Enter in a row's text print.
- **Print** did nothing, and jumped to the Image panel, after adding a small picture: its fitted **Scale %** passed the box's own maximum, and the box's range check held the print back.
- A field dragged above the label's top edge, or a **Y** with a fraction, failed to render, and the page then set the label to 384×96. A field now stops at the top edge, **Y** is a whole number, and a failed render leaves the label's size alone. The server's failure answers carry the size the body asked for, not 384×96.
- **Undo** after picking a model or a roll kept the new model or roll in the menu; it now puts the old one back. **Undo** also put back an old address, connection and density, which it now leaves alone, and did not turn the view back after **Vertical**, which it now does.
- Turning a field by its round handle, and nudging one with the arrow keys, could not be undone. Each is a step now, repeated nudges as one.
- **Undo** was enabled when the page opened with a printer it had picked by itself, and emptied the label.
- Loading a layout with one bad field cleared the label before refusing it. The layout is checked whole first.
- After loading a layout, or picking a printer whose roll could not be read, the **Label** menu could list another model's rolls.
- Picking a printer of another model read its roll twice, opening the printer twice, and the roll's message was replaced by the preview's at once.
- **Copy** of a turned field landed on top of it, and lost its angle. **Wrap** on a field turned to run along the roll wrapped it to the roll's width.
- A Bluetooth print could go to another printer: the print channel was looked up among every device BlueZ knew, and a printer used earlier stays connected. It is now the opened device's own.
- A print that failed after it had started, a refused page size or a row left unanswered, left the printer in the job; it now ends with `PrintEnd`. A stray byte ahead of the printer's answer is stepped over instead of failing the job or hiding the printer from a scan, and a one-byte model id reads as the spec says.
- A Bluetooth answer could be handed over twice, or an earlier session's answer taken for this one's, when it came just as a read gave up waiting.
- A D11_H, a 300 dpi head, found over Bluetooth was offered as a D11.
- Scanning a serial port whose carrier was down, with `CLOCAL` off, could hang the server.
- One request with a field at the far end of its numbers, such as `x` of 9223372036854775807, stopped the server. A long line turned 90 degrees asked for gigabytes of memory; one longer than any label is now `TextTooLarge`. A line ending in `\r` drew a missing-glyph box and moved aligned text.
- One connection that sent nothing, as a browser's spare one does, held every other request and the idle stop.
- **Quit** waited for the browser to close when `xdg-open` ran it in the foreground.
- A request with the cookie and a body larger than 8 KB was refused as a bad token.
- Two niimbench servers open at once each signed the other's page out; the cookie's name now carries the port.
- A runtime source whose name needs percent-encoding, such as `my record`, could be installed but not read or deleted.
- `.niimbench.token` was left behind after the server stopped, and the startup address in a log of stdout and stderr together was overwritten by the lines after it.
- A boot list whose `http` row could not start crashed with a panic, or a use-after-free when a second `http` row was listed. It now stops with `HttpInactive`.
- `niimbench print --image` crashed on a PGM with very many comment lines.
- `tools/trace.sh --token` never cleared the log, and without `--token` could not print one; it now reads `.niimbench.token`. `make trace-test` could not fail on a missing step, `make stray-test` left a folder behind, the doc link check dropped `_` from headings, and `make labels` emptied the catalogue when the download failed.
- The edit right after an **Undo** could not be undone on its own: the next **Undo** jumped past it, or did nothing. Undo now compares a new state with the top of its history, not with the last state it restored.
- **Undo** and **Redo** were enabled on a page just opened, with nothing to undo. They now start disabled.
- Loading a layout whose background image could not be restored said so for a moment, then the refresh after the load replaced the warning with a plain "loaded". The warning now stays.
- A picture you have not moved or scaled is fitted to the label again when the **Label** menu, the model, **Width** or **Height** changes the label's size. It used to keep the old fit and could hang off the new label.
- `POST /api/sources` refuses a name a plugin already uses, as `DELETE` does. It used to add a second record that no read saw, and a `DELETE` of the name then removed the plugin's own record.

## [0.6.0] - 2026-10-20

### Added

- **Bluetooth on macOS.** On a Mac, niimbench finds and prints to a Niimbot
  printer over Bluetooth through Apple's CoreBluetooth. Build it from source
  for now. The first scan asks whether the terminal may use Bluetooth, and a
  printer's address on a Mac is the UUID macOS gives it. USB on a Mac is not
  supported yet.
- **Copies**, beside **Print**: print the label up to 99 times in one job. A D11 or D110 prints the copies itself; a B-series printer gets the job once per copy.
- **Sync clock**, at the right end of the printer status line: copies this computer's date, time and time zone to the printer's clock, so the date button on a D110 prints today instead of 1970.

### Changed

- A Bluetooth print no longer waits on fixed sleeps for the printer's answers. Each command used to sleep half a second before it looked, 2.6 s for a print's five setup commands, and a status the printer repeated unchanged was taken for no answer and waited out a 3 s timeout. niimbench now subscribes to the notifications BlueZ announces on the bus, one per answer, identical ones included, and takes each as it arrives.
- A print sends a run of blank rows as one packet, and a run of identical rows as one packet with a repeat count, up to 255 rows each. Every packet waits for the printer's acknowledgement, about 25 ms over Bluetooth, so a mostly white 12×40 label spent 7 s on 304 packets; it now sends a few dozen. This is in the shared print path, so every model and connection gets it.

### Fixed

- A D11 or D110 could print one label twice, both copies whole: a D110_M did it now and then, with nothing but niimbench talking to it. It speaks protocol 4, and niimbench sent it the older D110 sequence, which never tells the printer how many pages and copies the job has. A D-series job now asks the printer's protocol version first; on protocol 4 it sends upstream's D110M_V4 sequence, one page and one copy, and below it the D110 sequence with `PrintClear` and `PrintQuantity` 1. A second copy that starts anyway is named in the trace.

## [0.5.0] - 2026-10-19

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

[Unreleased]: https://github.com/ywy50/niimbench/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/ywy50/niimbench/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/ywy50/niimbench/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/ywy50/niimbench/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ywy50/niimbench/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/ywy50/niimbench/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/ywy50/niimbench/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/ywy50/niimbench/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/ywy50/niimbench/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/ywy50/niimbench/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/ywy50/niimbench/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/ywy50/niimbench/releases/tag/v0.1.0
