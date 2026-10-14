# Logo and screenshot

The niimbench logo kit, and the screenshot the root README shows. The docs index is [../README.md](../README.md).

The mark is a die-cut label with an `n` in square thermal dots. The wordmark is Sora Bold, drawn as outlines so no font is needed to show it, with the dots over its two `i`s replaced by the mark's square dots. Sora is under the SIL Open Font License 1.1, which allows a logo made from its outlines.

## Which file

| File | Use it for |
|---|---|
| [logo-light.svg](logo-light.svg) | The logo on a light background: the README, docs, slides |
| [logo-dark.svg](logo-dark.svg) | The logo on a dark background. The README picks between the two with `prefers-color-scheme` |
| [logo-mono.svg](logo-mono.svg) | The logo in one ink, black: anything printed, a label from this bench included |
| [mark-light.svg](mark-light.svg), [mark-dark.svg](mark-dark.svg) | The mark alone, on a transparent background |
| [icon.svg](icon.svg) | The mark's dots on a filled blue tile, which reads on any background and at 16 pixels: the favicon, which the editor inlines, an app icon, an avatar |
| [icon-512.png](icon-512.png), [apple-touch-icon.png](apple-touch-icon.png) | `icon.svg` at 512 and 180 pixels, for places that take no SVG |
| [social-preview.png](social-preview.png), [social-preview.svg](social-preview.svg) | The 1280×640 card GitHub shows for a shared link. It is set by hand, under the repository's Settings → Social preview |
| [editor.png](editor.png), [editor.drive.js](editor.drive.js) | The README's screenshot, and the steps `make drive` runs to take it |

The colours are the editor's own: accent `#0b62d4` and ink `#1b1c1f` on light, accent `#6ba6ff` and ink `#e7e9ee` on dark. The two dots over the `i`s always take the frame's colour. Leave clear space round the logo at least the frame's corner radius.

## Refresh the pictures

The PNGs are rendered from the SVGs with `rsvg-convert`, from this directory.

The icons:

```sh
rsvg-convert -w 512 -h 512 icon.svg -o icon-512.png
rsvg-convert -w 180 -h 180 icon.svg -o apple-touch-icon.png
```

The social card, whose two lines of text are set in Noto Sans and Noto Sans Mono:

```sh
rsvg-convert -w 1280 -h 640 social-preview.svg -o social-preview.png
```

The README screenshot, from the repository root:

```sh
make drive STEPS=docs/assets/editor.drive.js SIZE=1440x900 DRIVE_OUT=docs/assets
```
