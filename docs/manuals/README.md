# Manuals

Vendor documentation, kept for the hardware facts the code has to match. These are not our pages: read them for what the maker states, and leave behaviour in the subsystem page that owns it.

| File | What it is |
|---|---|
| [d110.md](d110.md) | The D110's specification, indicator table, and troubleshooting in English |
| [d110_m.md](d110_m.md) | The D110_M's own facts: the model id, and that it is BLE only |
| [niimbot-d110-user-manual-ru.md](niimbot-d110-user-manual-ru.md) | The same manual as text, in the original Russian, so it can be searched |
| [niimbot-d110-user-manual-ru.pdf](niimbot-d110-user-manual-ru.pdf) | The vendor PDF the text came from |

The D110 PDF was published by a reseller; the Russian text was extracted from it with `pdftotext`, and the PDF's tables arrive as column lists rather than rows.

## The community wiki

The [NIIMBOT community wiki](https://printers.niim.blue/) is the only written source for the wire protocol, and it is a better reference than anything the vendor prints. A copy is under [upstream/](upstream/README.md) so a page can be read and searched offline; the useful ones are:

| Page | What it is |
|---|---|
| [upstream/interfacing/proto.md](upstream/interfacing/proto.md) | Every packet, both directions, with payload layouts |
| [upstream/interfacing/connecting.md](upstream/interfacing/connecting.md) | BLE characteristic, the two addresses, USB |
| [upstream/interfacing/print-tasks.md](upstream/interfacing/print-tasks.md) | The sequence a print job runs through |
| [upstream/other/label-types.md](upstream/other/label-types.md) | The label type numbers, and where a roll's dimensions live |
| [upstream/hardware/models.md](upstream/hardware/models.md) | Model ids, DPI, printhead widths, density ranges |

Print geometry for each model lives in [../subsystems/printer.md](../subsystems/printer.md), and the transport a model needs is in [../subsystems/http.md](../subsystems/http.md). Add a manual here only when the model's own document says something the code depends on.
