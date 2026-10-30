# Label catalogue

Every label the vendor cloud offers in the sizes its own template endpoint groups by series, and the rolls added from a tag the cloud answered for, keyed on the barcodes an RFID tag on the roll can carry. The app reads a roll's barcode from the tag and looks it up here to size the canvas, so this is the reference for what a roll can be. [catalogue.json](catalogue.json) beside this page holds every roll; this page counts them.

`catalogue.json`, the copy the binary embeds and this page are written by [tools/fetch-labels.py](../../tools/fetch-labels.py); do not edit them by hand. [Regenerating](#regenerating) says how.

## Coverage

| Rolls | Sizes | Other codes a tag may carry | Added from a tag |
|---|---|---|---|
| 219 | 26 | 0 | 1 |

| Model | Rolls listed for it |
|---|---|
| b1 | 127 |
| b18 | 5 |
| b21 | 133 |
| d11 | 46 |
| d110 | 45 |

A roll counts for a model when the vendor lists it for a B1, B18, B21, D11 or D110, its variants included: a D110_M is a D110 here, and a D11S a D11. A roll listed for none of them is kept, and its size may still be printable if a roll measures that way.

## A row

One roll per line of `catalogue.json`:

| Field | What it is |
|---|---|
| `barcode` | The vendor's barcode for the roll |
| `codes` | Its other barcodes, any of which the tag may carry instead: the vendor gives one roll several. Each code names one roll |
| `name`, `name_zh` | The vendor's English and Chinese names |
| `width_mm`, `height_mm` | The size as the vendor lists it, in whole millimetres, a half rounded up. Some rolls are listed length first, 40x12 for a 12 mm roll of 40 mm labels; the server turns those to face the head |
| `paper_type` | 1 gap, 2 black, 5 transparent, 10 black mark gap; niimbench does not send it and always tells the printer label type 1, a gap label |
| `consumable_type` | The vendor's consumable kind |
| `machines` | The printers the vendor lists the roll for |
| `ours` | The models this bench drives among them |

`src/catalogue.json`, the copy the binary embeds, keeps `barcode`, `codes`, `name`, the size and `paper_type`, with the Chinese name where there is no English one.

## Looking up a roll

The trace names the barcode a roll's tag answered with. This finds the roll a barcode names, here `6972842743558`; put the trace's barcode in its place:

```sh
jq -c '.[] | select(.barcode == "6972842743558" or (.codes | index("6972842743558")))' docs/labels/catalogue.json
```

## Sizes

| Size, mm | Rolls | Models |
|---|---|---|
| 12x40 | 3 | d11, d110 |
| 14x30 | 3 | b18, d11, d110 |
| 22x12 | 2 | d11, d110 |
| 28x14 | 1 | d11, d110 |
| 30x12 | 2 | d11, d110 |
| 30x14 | 2 | d11, d110 |
| 30x15 | 16 | b1, b21, d11, d110 |
| 30x20 | 1 | b1, b21 |
| 30x30 | 2 | b1, b21 |
| 30x50 | 1 |  |
| 40x12 | 23 | b1, b21, d11, d110 |
| 40x14 | 3 | b18, d11, d110 |
| 40x20 | 21 | b1, b21, d11, d110 |
| 40x30 | 34 | b1, b21, d11, d110 |
| 40x60 | 8 | b1, b21 |
| 40x70 | 6 | b1, b21 |
| 50x14 | 2 | b18, d11 |
| 50x15 | 2 | b21, d11, d110 |
| 50x30 | 66 | b1, b18, b21, d11, d110 |
| 50x50 | 6 | b1, b21 |
| 50x70 | 3 | b1, b21 |
| 50x80 | 4 | b1, b21 |
| 60x40 | 2 | b1, b21 |
| 70x50 | 2 | b1, b21 |
| 70x80 | 1 |  |
| 80x50 | 3 | b1, b21 |

## Regenerating

Refresh the whole catalogue from the vendor cloud:

```sh
make labels
```

The script walks `industryTemplate/sizes` and then pages through `industryTemplate/page` for each size in both orientations. It needs no key and no account. It keeps one row per barcode and writes the JSON, the embedded copy and this page. The rows in `added.json` whose barcode the listing does not answer for are kept.

Add the rolls a server saved from the cloud, from `.niimbench.rolls.json` in the folder it runs from:

```sh
make add-rolls
```

A tag the catalogue does not know, once the server has asked the cloud about it, is saved there. This asks the cloud for that barcode's full record, keeps it in `added.json`, and writes it into the catalogue. `ROLLS=` names another saved file, such as the app's under `~/.local/state/niimbench` or `~/Library/Application Support/niimbench`, or a barcode.

Check that the JSON, the embedded copy and this page agree, and that no code names two rolls:

```sh
make labels-check
```
