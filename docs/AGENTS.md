# AGENTS.md — documentation standard

This file is the documentation standard for niimbench. The tree index is [README.md](README.md). Standing orders for code live in the root [AGENTS.md](../AGENTS.md).

The folder layout follows [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) `docs/`: an architecture map, one reference page per subsystem, cookbooks, a user guide, development notes, and reviews. This repository does not copy the harness catalogs, VitePress site, bilingual triples, or `verify-doc-budgets` gates. English is the only language here. Add a `.zh.md` and a `.i18n.yaml` sidecar only when a real translation exists.

## One home per fact

Each fact has one home. Other pages link there.

| Tier | Job | Does not belong there |
|---|---|---|
| Root [AGENTS.md](../AGENTS.md) | Standing orders, one to three lines, each linking its home | Procedures, route tables, model tables |
| This file | How to write and place docs | Product behavior |
| [architecture.md](architecture.md) | Ordered map of the process: layers, boot, where a change starts | Field-by-field HTTP bodies, termios bits, glyph metrics |
| [subsystems/](subsystems/README.md) | One reference page per subsystem: types, routes, wire, lifetimes | A teaching walkthrough of the editor |
| [cookbook/](cookbook/README.md) | Numbered procedures with a check at the end | Design history |
| [user/](user/index.md) | Product guide for someone using the editor or the CLI | Plugin `apply` snippets, test inventories |
| [development.md](development.md) | Build, run, boot list, where the docs live | A second copy of the route table |
| [glossary.md](glossary.md) | Short definitions used across pages | Procedures |
| [testing.md](testing.md) | What `make test` locks in | How to add a plugin |
| [reviews/](reviews/README.md) | The copied Cordis checklist | A status report of this tree |
| [templates/](templates/README.md) | Files a person or a new page starts from | Behavior that the subsystems pages already own |
| [labels/](labels/README.md) | The label rolls the vendor catalogues, and the generator that copies them | Label geometry the app derives, which is [subsystems/printer.md](subsystems/printer.md) |
| [manuals/](manuals/README.md) | Vendor and upstream documents kept for the hardware facts | Our own behavior |
| [cordis-primer.md](cordis-primer.md) | Zig names for the Cordis ideas this kernel implements | The TypeScript package API |

Placement: a new route goes on [subsystems/http.md](subsystems/http.md), and architecture keeps the one-line role. A new plugin procedure goes in the cookbook. A button the editor shows goes in the user guide. A copied file, whether a vendor manual or the label catalogue, keeps its provenance and the command that refreshes it.

## Kinds

A tutorial is an ordered path to an outcome. [user/guide/index.md](user/guide/index.md) is the tutorial. A reference defines current behavior for one subject and is not a lesson. Subsystem pages, architecture, the glossary, testing, and development are references. A cookbook is a numbered procedure.

A page describes its own subject. It names a child by purpose and links the child for the detail.

## Writing rules

- Document current behavior. History stays in commits.
- Use relative links to files in this repository.
- Update the owning subsystem page in the same change that changes that subsystem's contract.
- Do not restate a route table, model table, or glyph number that already has a home.
- Do not mark sections "implemented" or "future". The tree is the status.
- A new reference page starts from [templates/reference.md](templates/reference.md) and is added to [README.md](README.md) and, when it is a subsystem, to [subsystems/README.md](subsystems/README.md).
- A layout JSON file under `templates/` must load through the editor's Load layout control. The field names are the label body in [subsystems/http.md](subsystems/http.md). Saved layouts omit `background_b64`.

## Page skeleton

Copy [templates/reference.md](templates/reference.md). Fill the title, the one-sentence ownership line, and the sections that page actually has. Delete unused headings. Link the index at the top.
