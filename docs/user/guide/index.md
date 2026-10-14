# Use the editor

Start the server from the [root README](../../../README.md#quick-start). The process prints one line:

```text
http://127.0.0.1:<port>/?token=<32 hex chars>
```

Open that URL. The browser stores the token in a cookie and lands on `http://127.0.0.1:<port>/`, so the address bar no longer shows it. This guide begins after that page is up.

The page opens with one text field that says `niimbench`, centred on the label in DejaVu Sans at the largest size up to 32 dots that fits across the roll. The preview is the grayscale the printer will get. `POST /api/render` and `POST /api/print` share that drawing path.

## Arrange the panels

The page is four panels on a grid: **Preview**, **Label and printer**, **Text** and **Image**. Drag a panel by its title to move it, and drag the striped corner at its bottom right to resize it. Both snap to the grid, which is 24 columns across the window.

The other panels make room the way a dashboard's do. A moved panel follows the pointer over a dashed outline of where it will land, and the panel it lands on moves below it. A resized panel stays where it is and pushes the panels it grows into down. No panel is left with a gap above it: each rises until it meets the one above. A panel that holds more than it has room for scrolls.

The label in **Preview** is drawn as large as the panel allows, in whole multiples of its pixels when it fits at least once, so a bigger **Preview** panel shows a bigger label.

The arrangement is kept in this browser and comes back the next time the page opens. It is not part of a label: **Save layout** does not write it and **Undo** does not move a panel. **Reset panels**, in the header, puts every panel back where the page first had it.

A window 52rem (832 pixels) wide or narrower has no room for a grid. There the panels are stacked full width in the order above, each as tall as what it holds, and they do not move.

## Pick a label size

**Label** lists the die-cut rolls for the selected **Model**. B1 and B21 share one list, D11 and D110 share another, and B18 has its own. Choosing a roll writes the width and height. The page opens on the roll that model ships with: 50×30 mm for B1 and B21.

A new roll — another **Model**, another **Label**, or a typed width or height — keeps the text on it. A field the new roll would cut off keeps its place relative to the roll and gets smaller until the whole field fits, so switching from a B21 to a D11 does not leave the text off the edge. A field that was already clipped on the old roll is left as it is, and **Undo** puts the roll and the fields back together.

A roll wider than the print head uses the head width. A 50 mm B21 roll is 384 dots across, and a 15 mm D11 roll is 96. **Custom** leaves whatever width and height you type. Changing the model to one that does not take the current roll switches to that model's roll and sets the numbers again. Which rolls those are is in [../../subsystems/printer.md](../../subsystems/printer.md).

## Place a field

**Image** takes a picture — a photo, a logo, a QR code saved as a PNG — and draws it on the label in one ink. A picture is fitted to the view when it is imported, so it lands on the label whatever its shape and whichever way the view is turned, and the fitting is redone if the label or the view changes shape while you have not touched it. Once you have moved it, it stays where you put it.

The frame drawn round the picture is what you grab: drag inside it to move, drag a corner to scale up or down, and drag the round grip above it to turn it. Scaling always re-samples the picture you imported, so enlarging it does not magnify a reduced copy. The **Scale %**, **Rotation**, **Left** and **Top** boxes do the same thing by number, **Fit** and **Fill** re-place it, **Turn 180°** flips it, **Reset image** puts it back centred, fitted and upright, where an import puts it, and **Remove image** takes it off the label.

Click a field's box or the picture to select it: its outline turns solid and thicker, and a field's row is shaded. **Delete** (or **Backspace**) removes what is selected, the same as the row's **Remove** or **Remove image**, as long as you are not typing in a box. **Undo** brings a removed field back; it does not cover the picture.

**Image threshold** chooses which part of the picture becomes ink: everything darker than the slider prints black and everything lighter prints white. A label has one ink, so a photograph is reduced to two tones rather than dithered, and the slider is how you pick what survives.

**Grid** draws faint guides on the preview every 16 dots (2 mm), so a field can be placed by eye against something. The guides are drawn over the page only; they never reach the printer.

**Add text** appends a row. Each row has its text, a **font**, a **size**, an alignment, an `x` and `y` in pixels, an angle, and **Wrap**, **Fit**, **Copy** and **Remove**. Size is the line height in dots, any whole number from 1 to 1024 — dragging a corner of the field's box sets the same number — and it is a different thing from **Label** in the **Label and printer** panel, which is the size of the roll itself. 8 dots is 1 mm. Every size is allowed, including one too wide for the roll: the box turns red and the row says it is clipped, and **Fit** or **Wrap** fixes it. **Copy** adds another field with the same text, font, size, and alignment directly below. Inputs apply when they change.

**Font** picks the typeface a row is drawn in, from the fifteen free fonts built into niimbench: sans, serif and monospaced faces from DejaVu, Liberation, Open Sans, Fira Sans, Noto and Hack, with bold versions of the sans faces. A new row starts in DejaVu Sans. The same size can look larger or smaller from one font to the next, because size is the whole line, including the room a font keeps for accents and descenders; the box always shows what that line takes on the label. The list, with each font's licence, is [src/fonts/README.md](../../../src/fonts/README.md).

**Fit** centres the field on the label and makes it as large as the label allows: the largest size whose box, turned the way the field is, stays a millimetre inside every edge. It grows a small field and shrinks a clipped one, in one click. With **Keep text upright** on in **Vertical**, the field is turned with the view, so **Fit** fills the width the preview shows. If not even a 1-dot line fits, the field is left as it is.

**Wrap** breaks a row's text into lines that fit, from the row's `x` to the roll's edge, so a long value stops being clipped. A newline you typed is a paragraph the button keeps and wraps on its own. A word wider than the roll is cut, because the renderer has no hyphen to draw.

The arrow keys nudge a field by one pixel while its `x` or `y` input has focus; hold Shift for ten. A nudge stops at the label's edges and never makes a coordinate negative.

A newline in a row's text starts a second line, so one field can hold a small block. Press Enter to add a line and Ctrl+Enter to print; the box on the preview grows to hold every line, and Save layout keeps them.

The alignment decides what `x` means: the left edge, the centre, or the right edge of the block. `center` and `right` measure the widest line of the block, so a short line in a centred block ends where the row says it should. Each line is placed by its own width, so a short line in a centred block is centred. The box you drag follows the placed line, and the `x` input still shows the anchor.

Changing the alignment never moves the text: the block stays where it is, and `x` changes to the edge the new alignment names. What it changes is what happens next — the lines of a block line up on that edge, and text that gets longer grows away from it. A left edge left of the label, which a turned field on a narrow roll can have, is a negative `x`.

## Turn the text

There are two turns and they are independent. **Orientation** is how the editor draws the page. A field's **angle** is how its letters are drawn, and it is the only one the printer hears about.

### Orientation: the view

**Horizontal** and **Vertical** choose which way the *page* is drawn in the editor. The printer is always sent the page as it is.

| | The editor shows | The printer is sent |
|---|---|---|
| **Horizontal** | the roll as it is: width across the head, height along the tape | the page, unchanged |
| **Vertical** | the roll turned a quarter turn counter-clockwise, so the tape runs left to right along the window | the page, unchanged |

In **Vertical**, the letters are never mirrored: the picture is turned, so a field's angle shows on screen as that angle less the view's quarter turn. A field at `0` reads across the roll, which in Vertical runs up the window; a field at `90` reads along the tape, which runs left to right. Whatever the orientation, the width and height the printer receives are the page's own — orientation is a property of the editor's window, not of the job.

**Keep text upright**, next to the buttons and on by default, turns every field with the view: **Vertical** adds `90` to each field's angle and **Horizontal** takes it off again, so the letters read the same way up in the window before and after the switch. A field the turn would push off the label is brought back on, smaller if it has to be. With it off, the buttons turn only the window: the fields keep their angles, and text at `0` runs up the page in Vertical.

A new field starts at the view's own turn — `0` in Horizontal, `90` in Vertical — so it reads upright whichever way the window is turned. Dragging a field moves it with the pointer in either view.

### Angle: the letters

Each row has a degrees input. `0` is the letters across the tape, `90` turns them to run along it, and any angle between or beyond those is allowed. Drag the round handle on a box to turn it, or type the angle; the input follows the drag, so it always shows where the field is. While you drag, the box and its letters turn on the page itself; the server draws the field at its new angle once, when you let go. **Snap 15°** restricts dragging to fifteen-degree steps, and typed angles are never snapped.

### What a box promises

A dashed box is the field, not a decoration, and it holds to six things at every angle:

- **It is the size of the text.** The box is the turned block's own footprint, so it grows with the whole word at the size in the field's row and with the angle it is drawn at — a long word is a long box, and the same word at `45` is a square one. It is never the size of a different size or a different angle.
- **A corner resizes it.** Each corner has a small square. Drag one and the text grows or shrinks with the pointer while the opposite corner stays where it is, the way a corner works in an image editor; the preview re-renders the letters as you go, and the row's size follows. It works the same on turned text.
- **It is parallel to its text.** The box turns with the field, so its long edge and the line of letters stay together.
- **The round handle is on the text's top side.** It sits above the top of the text, not above the top of the window and not beside the box, whichever way the text has been turned.
- **Dragging moves it one dot per dot.** Grab anywhere inside the box and it follows the pointer without jumping or re-anchoring. It is not stopped at the edge of the label: dragging past the edge is how a field becomes clipped, and the box says so. **Snap 15°** applies to turning only; a move is free.
- **It says when a field is clipped.** A box that reaches past the page turns red, and the line under the window counts the clipped fields, because the renderer clips rather than wraps.

Drag the dashed box on the preview to move that field. **Clear text** removes every row, which is the way to start from a blank label; **Undo** brings them back.

A field whose ink would pass the right or bottom edge is outlined in red and marked clipped. The renderer draws the part that fits. It does not wrap.

## Undo and redo

**Undo** and **Redo**, in the header, walk the label's changes, and `Ctrl+Z` and `Ctrl+Shift+Z` (or `Ctrl+Y`) do the same from the keyboard. A change is a field you add, copy, remove, move, retype, or restyle, a printer setting, or a loaded layout. A drag is one change, recorded when you press rather than when you drop, and a run of keystrokes in one field is one change too.

The history holds the same JSON that **Save layout** writes, so it does not cover the background image. Typing into a number or text control records the state before the first keystroke, so the first edit to the width or height is undoable like any other. **Reset label** is the baseline: it clears the history rather than adding to it, which is why **Undo** starts disabled. The history keeps the last hundred changes.

## Save and load a layout

**Save layout**, in the header, downloads `niimbench-label.json`: width, height, fields, density, model, connection, address, and rotation, and for each field its text, position, font, size, alignment and angle. The picture is left out on purpose.

**Load layout** reads that JSON. It needs an object with a `fields` array of at most 64 objects. A field's `size` is its line height in dots. A layout saved before sizes were in dots says `scale` instead, and loads at `scale * 11` dots. A field's `font` is one of the built-in font ids; a layout without one, or naming a font this build does not have, loads in DejaVu Sans, and the row's menu shows it. A `background_b64` field is ignored and the status line says the background was not loaded.

[../../templates/example-label.json](../../templates/example-label.json) is a file in that shape. It draws a title in a bold font and a part number in a mono font, on a 384×96 B21 label.

The editor has no controls for sources: it draws literal text only, and drops a layout's `source` and its fields' `key` on load. The HTTP routes still take `source` and `key`; how sources are installed and read is [../../subsystems/sources.md](../../subsystems/sources.md).

## Pick a printer

**Found Niimbot devices** is the list of printers the last scan found. The page scans once on load and, when that scan finds exactly one printer, selects it — so the model and the roll are on the canvas before you touch anything, and the page opens on the roll you actually have rather than on a default size. **Find nearby** scans again, asks Bluetooth for an inquiry, and also selects a lone printer; the inquiry takes a couple of seconds and can see a printer that was never paired with this machine.

The list is always shown, even when the scan found a single printer: one shape for the page no matter how many printers are around. Pick one and the whole printer row follows it: **Connection** and **Address** are set, and **Model** moves to the head that printer has, which also puts that model's label roll on the canvas. A device whose model is not one of the five says so; pick **Model** by hand in that case.

The scan is in [../../subsystems/printer.md](../../subsystems/printer.md). **Connection** and **Address** stay editable, so an address the scan cannot reach, such as a printer behind another machine's Bluetooth, is still reachable by hand.

## Print

The **Printer** line on the header, left of the status line and **Print**, says what this page knows: a blue dot and `No address yet` when nothing is chosen, a green dot with the connection, model and `ready` once an address is set, and an amber dot while a job is being sent. It always describes the printer picked now: picking another one from the list, or loading a layout, updates it at once. Under it, `Last job:` says how the last print went — `printed`, or the error in red — and stays until the next print, so a failure is still there to read without hiding which printer is picked. It is the page's own state, not the printer's indicator light, which is a separate thing described in [manuals/d110.md](../../manuals/d110.md).

Set **Model**, **Density**, **Orientation**, **Connection**, and **Address**.

**Density** is how hot the print head burns each dot: higher prints darker and bolder, lower lighter. It changes nothing about which dots print, so the preview, which shows exactly that, looks the same at every density; the difference is only on the paper. Each head has its own range, 1 to 5 on the B1, B21 and other B-series heads and 1 to 3 on the D11, D110 and B18, and the input offers the picked model's range: picking a D110 with density 5 sets it to 3, the most that head takes.

 USB wants a tty such as `/dev/ttyACM0`. Bluetooth wants the MAC the printer list shows; a BLE-only model such as the D110_M is reached over its print characteristic, and picking a printer fills in the address, the model and the roll's size for you. The label is never wider than the picked head, even when its roll cannot be read: picking a D110 narrows a 384-dot page to the head's 96 dots, which is what the printer would otherwise refuse as `TooWide`. **Print**, at the top right of the page, sends the same label body the preview used, plus those printer fields; it stays in view however the panels are arranged. The status line and the `Last job:` line under **Printer** show `printed` or the error name. A job takes as long as the printer does, so **Print** is disabled until the answer arrives: a second click or a second `Ctrl+Enter` cannot send the same label twice.

Text starts upright, in the middle of the label. Drag the round handle on a field to turn that field. The degree box shows the angle and accepts a typed one. **Snap 15°** locks the drag to 15 degree steps. The label itself stays the roll, so a 15 mm head stays 96 dots across. Picking a printer reads the roll and sets the label size when the tag and Niimbot's catalogue both answer.

B18, D11, and D110 densities above 3 are clamped to 3. Widths above the print head are rejected before any byte is written. Model limits are in [../../subsystems/printer.md](../../subsystems/printer.md).

## When something looks wrong

The process keeps a log of what it and the page have done, readable while it runs: `GET /api/trace` (with the session token) answers one line per event, oldest first, with a relative time. It records every roll read, every print and how it ended, and any error the page itself hit, so a label that came out wrong or a button that did nothing can be looked up rather than guessed at. `?clear=1` empties it, so the lines after that are only about what you did next.

`tools/trace.sh` does that around one command:

```sh
tools/trace.sh --port 8080 -- make print IMAGE=label.pgm ADDR=/dev/ttyACM0
```

The whole log is described in [subsystems/trace.md](../../subsystems/trace.md).

## Continue

- [Print one PGM from the CLI](../../../README.md#quick-start)
- [Label body fields](../../subsystems/http.md)
- [Where a source lives](../../subsystems/sources.md)
- [Loadable layout and the page skeleton](../../templates/README.md)
