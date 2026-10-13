# Documentation

niimbench docs follow the DeepSeek Harness folder layout, scoped to this printer bench. Rules for writing them are in [AGENTS.md](AGENTS.md). Product use starts at [user/guide/index.md](user/guide/index.md).

| Path | Kind | Owns |
|---|---|---|
| [architecture.md](architecture.md) | reference | Process map: printer core, HTTP, editor, boot |
| [cordis-primer.md](cordis-primer.md) | reference | Zig names for context, fiber, inject, effect |
| [development.md](development.md) | reference | Zig 0.17 commands and the boot list |
| [glossary.md](glossary.md) | reference | Terms used across these pages |
| [testing.md](testing.md) | reference | What `make test` locks in |
| [subsystems/](subsystems/README.md) | reference | Printer, HTTP, sources, trace, text |
| [cookbook/](cookbook/README.md) | procedure | Adding a plugin |
| [user/](user/index.md) | tutorial | Using the editor and the CLI |
| [templates/](templates/README.md) | template | Loadable label JSON and a blank reference page |
| [labels/](labels/README.md) | reference | Every label roll the vendor catalogues, by size and barcode |
| [manuals/](manuals/README.md) | manual | Vendor documents for the hardware, e.g. the D110 |
| [reviews/](reviews/README.md) | checklist | Copied Cordis review, not a tree status report |

The root [README](../README.md) is the project entry. Standing orders for agents are in the root [AGENTS.md](../AGENTS.md).
