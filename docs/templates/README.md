# Templates

Files to copy. Behavior they rely on lives in the linked page, not here.

| File | Use |
|---|---|
| [example-label.json](example-label.json) | Load this from the editor. It is a saved layout with a literal title and a field bound to the `example` source. |
| [reference.md](reference.md) | Starting point for a new reference page. Add the page to [../README.md](../README.md). |

## Layout JSON

Load layout requires an object with a `fields` array. Each field may set `text`, `key`, `x`, `y`, `font`, `size`, `align_mode`, and `rotation`. `font` is one of the ids in [../../src/fonts/README.md](../../src/fonts/README.md), DejaVu Sans when it is missing or unknown. `size` is the line height in dots. A layout that says `scale` instead, from before text had sizes in dots, loads at `scale * 11`. Optional label fields are `width`, `height`, `model`, `density`, `rotate`, `conn`, `addr`, and `source`. At most 64 fields.

Save layout writes that object and deletes `background_b64`. The render body, which can include a background, is specified in [../subsystems/http.md](../subsystems/http.md).

`example-label.json` draws `niimbench` in DejaVu Sans Bold at size 32 from `(4, 4)`, and the `sku` key of the `example` source in DejaVu Sans Mono at size 20 from `(4, 44)`, on a 384×96 label, model `b21`, density 5, USB. The second field starts below the first one's 32-dot line, with 8 dots between. `make canvas-test` renders this file through `POST /api/render`, so a template the server would refuse fails the build.
