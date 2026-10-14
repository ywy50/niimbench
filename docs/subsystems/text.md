# Text

How a field's text becomes dots on a label: the embedded fonts, what `size` means, how a line is measured, and how glyph outlines are filled. `src/font.zig` reads and rasterises the fonts, and `src/label.zig` lays the lines out, aligns them and turns them. Index: [../README.md](../README.md).

## Contract

### Fonts

A field's `font` is the id of one of the fonts embedded in the binary; the default is `dejavu-sans`. The list of fonts, their files, versions and licences is [../../src/fonts/README.md](../../src/fonts/README.md), and `font.fonts` in `src/font.zig` is the same list in code. The editor's font menu shows every font the server reports at `/api/label/metrics`.

### Size

`size` is the height of one line in dots: the font's ascender to its descender, so descenders are inside it. It is any whole number from 1 to 1024; a larger or smaller one is drawn at the nearest end of that range. Eight dots are a millimetre on every model here. The lines of a block stack `size` dots apart, so a block of three lines at 20 is 60 dots tall.

Fonts reserve different room above and below their letters, so the same `size` draws taller capitals in DejaVu Sans than in Open Sans or Noto Sans. The box a field gets is the line height either way.

### Width

A line is as wide as the advances of its characters, scaled to the size and rounded up to a whole dot: `ceil(units * size / line_units)`, where `units` is the sum of the font's advance widths for the line's code points and `line_units` is the font's line height in its own units. A block is as wide as its widest line. There is no kerning: the editor measures with the same advance tables (see [http.md](http.md#metrics)), and a second table would be a second thing for it to agree with.

A character the font does not map — including every code point above U+FFFF — draws the font's missing-glyph box and measures as that box.

### Placement and turning

`x` is the left edge, centre or right edge of the block, as `align_mode` says, and each line is placed by its own width from that anchor. `y` is the top of the first line. A centred or right-aligned block can start left of the label, and is clipped there like at any other edge. It is never pushed back on: the editor draws its box where the block is, and a field turned a quarter turn on a narrow roll, whose upright line can be far longer than the roll is wide, would otherwise have its ink jump along the roll and out of the box as it grew. The renderer places the block itself, and `alignedX` gives the editor the same left edge.

`rotation` turns the block clockwise about its own centre. Each letter's outline is turned about that centre before it is filled, straight onto the label, so a turned stroke is put on the dots once and the dropout rule keeps it unbroken at any angle. Drawing the block upright and then turning its dots put every stroke on the dots twice, and a thin stroke at an angle came out stepped and broken.

### Filling outlines

`src/font.zig` reads TrueType outlines: simple glyphs, and composite glyphs built from offset, scaled or transformed parts, which is how most fonts make accented letters. Quadratic curves are flattened into straight pieces about two dots long. There is no hinting.

Each glyph is filled on its own, with the non-zero winding rule, the way a TrueType rasteriser does without hinting:

1. A dot is black when its centre is inside the outline.
2. **Dropout control.** Where a stroke is too thin to contain any dot centre — it passes between two of them — the dot under the middle of the stroke is inked anyway. This is checked across every row and down every column, so thin strokes of either direction stay unbroken.
3. **Specks.** The outline says how many counters a glyph has: the contours wound the other way from its largest one, so an `o` has one, a `B` two and an `i` none. Where a counter narrows to a point, a dot centre can land in that point and come out as a white dot cut off from the rest of the counter. When a glyph has more enclosed white regions than counters, the smallest extra ones are filled.

Inking a dot when the glyph covers half its area, which is what the renderer used to do, breaks exactly the strokes that matter on a label: a lower-case stem a dot and a half wide that straddles two dots covers neither by half, and the letter comes out with white gaps.

## Limits

- An id that is not an embedded font is `UnknownFont`, which `POST /api/render`, `POST /api/print` and `POST /api/label/track` answer with 400. It is never drawn in some other font.
- A block whose upright drawing grid would exceed 4096 × 4096 dots is `TextTooLarge`.
- Fonts must be TrueType `glyf` outlines with a `cmap` format 4 table. There is no kerning, no ligatures, and no shaping, so scripts that need shaping draw letter by letter.
- Below about 16 dots some letters lose detail: the dot of a bold `i` touches its stem, and small counters fill in. Strokes still do not break and no white specks appear; the tests hold that from 16 dots up.

## Related

- The label body and the metrics route: [http.md](http.md)
- The map: [../architecture.md](../architecture.md)
- What the tests hold: [../testing.md](../testing.md)
