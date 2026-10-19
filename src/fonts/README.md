# Fonts

The typefaces niimbench draws text in. `src/font.zig` embeds every file listed here with `@embedFile`, so a print never depends on what is installed on the machine that runs it. All of them are free to use, modify and redistribute; each family's licence is the file next to it.

| Id | Name | File | Version | Licence |
|---|---|---|---|---|
| `fira-sans` | Fira Sans | `FiraSans-Book.ttf` | 4.301 | [FiraSans-OFL.txt](FiraSans-OFL.txt): SIL Open Font License 1.1 |
| `fira-sans-bold` | Fira Sans Bold (the default) | `FiraSans-Bold.ttf` | 4.301 | [FiraSans-OFL.txt](FiraSans-OFL.txt) |
| `dejavu-sans` | DejaVu Sans | `DejaVuSans.ttf` | 2.37 | [DejaVu-LICENSE](DejaVu-LICENSE): Bitstream Vera licence, DejaVu changes in the public domain |
| `dejavu-sans-bold` | DejaVu Sans Bold | `DejaVuSans-Bold.ttf` | 2.37 | [DejaVu-LICENSE](DejaVu-LICENSE) |
| `dejavu-sans-mono` | DejaVu Sans Mono | `DejaVuSansMono.ttf` | 2.37 | [DejaVu-LICENSE](DejaVu-LICENSE) |
| `dejavu-serif` | DejaVu Serif | `DejaVuSerif.ttf` | 2.37 | [DejaVu-LICENSE](DejaVu-LICENSE) |
| `liberation-sans` | Liberation Sans | `LiberationSans-Regular.ttf` | 2.1.5 | [Liberation-LICENSE](Liberation-LICENSE): SIL Open Font License 1.1 |
| `liberation-sans-bold` | Liberation Sans Bold | `LiberationSans-Bold.ttf` | 2.1.5 | [Liberation-LICENSE](Liberation-LICENSE) |
| `liberation-serif` | Liberation Serif | `LiberationSerif-Regular.ttf` | 2.1.5 | [Liberation-LICENSE](Liberation-LICENSE) |
| `liberation-mono` | Liberation Mono | `LiberationMono-Regular.ttf` | 2.1.5 | [Liberation-LICENSE](Liberation-LICENSE) |
| `open-sans` | Open Sans | `OpenSans-Regular.ttf` | 3.003 | [OpenSans-OFL.txt](OpenSans-OFL.txt): SIL Open Font License 1.1 |
| `open-sans-bold` | Open Sans Bold | `OpenSans-Bold.ttf` | 3.003 | [OpenSans-OFL.txt](OpenSans-OFL.txt) |
| `noto-sans` | Noto Sans | `NotoSans-Regular.ttf` | 2.015 | [Noto-OFL.txt](Noto-OFL.txt): SIL Open Font License 1.1 |
| `noto-serif` | Noto Serif | `NotoSerif-Regular.ttf` | 2.015 | [Noto-OFL.txt](Noto-OFL.txt) |
| `hack` | Hack | `Hack-Regular.ttf` | 3.003 | [Hack-LICENSE](Hack-LICENSE): MIT, with the Bitstream Vera licence for the glyphs it derives from |

The id is what a field's `font` names and what a saved layout stores; the name is what the editor's menu shows.

## Where they come from

The files were copied unchanged from the Arch Linux packages `ttf-dejavu`, `ttf-liberation`, `ttf-opensans`, `ttf-fira-sans`, `noto-fonts` and `ttf-hack`, which install them under `/usr/share/fonts/`. The licence files are those packages' own, except `Noto-OFL.txt`: the package ships an Apache 2.0 text, but Noto 2.015's own name table states the SIL Open Font License 1.1, so that is the text kept here, under the copyright line the fonts carry.

To refresh a font, copy the newer file over the old one from the same package, and run `make test`. The test suite draws every letter and digit of every font at label sizes and fails if a stroke breaks or a white speck appears, so a file the rasteriser cannot read, or reads badly, does not ship.

## Adding a font

A font must be TrueType outlines (a `glyf` table, not CFF) with a `cmap` format 4 table, and must not be a variable font: `src/font.zig` reads only those. Add an `embed(...)` line to `fonts` in `src/font.zig`, put the file and its licence here, add a row above, and run `make test`. A file without the tables the reader needs fails the build rather than drawing nothing; a variable font would build and draw only its default instance, so check that by hand.
