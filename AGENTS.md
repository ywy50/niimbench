# AGENTS.md

niimbench is a Zig label bench. Every feature is a plugin. Read [docs/architecture.md](docs/architecture.md) before changing plugins. Follow [docs/AGENTS.md](docs/AGENTS.md) for documentation. The index is [docs/README.md](docs/README.md).

## Repository layout

The layout of the repository, file by file, is the table in [README.md](README.md#layout).

`src/default.patch.yml`, compiled into the binary, and `cordis.patch.yml`, used when you run from this directory, are the same boot list. Keep the two identical, including `inject`.

## Commands

Run every check:

```sh
make test
```

Serve the editor on a fixed port:

```sh
make serve PORT=8080
```

Read the log of the server running in this checkout, when someone reports what a print or the page did ([docs/subsystems/trace.md](docs/subsystems/trace.md)):

```sh
make trace
```

Look at the page in a headless browser, with your own steps or none (see `tools/drive.js`):

```sh
make drive STEPS=steps.js
```

Print a binary PGM over USB:

```sh
make print IMAGE=label.pgm ADDR=/dev/ttyACM0 CONN=usb
```

Zig is 0.17. `make test` is the check for a behavior change. Report the command you ran. Target details are in the [Makefile](Makefile).

## Standing orders

- New behavior is a plugin with `name`, `inject`, and `apply`. Register it in `src/plugins.zig` and in both patch files. The steps are [docs/cookbook/adding-a-plugin.md](docs/cookbook/adding-a-plugin.md).
- Publish services with `ctx.set` and listen with `ctx.on` or `ctx.effect`. Both are effects. A dispose test must show the registration is gone. [docs/cordis-primer.md](docs/cordis-primer.md) names the Zig types.
- Do not keep a second registry in a module global. The context is the registry.
- `inject` in the patch must match `Plugin.inject`. A mismatch is `error.InjectMismatch`. A missing coeffect leaves the fiber inactive until the service appears.
- Printer bytes on the wire are outside the effect system. Say so next to the send, and finish a job that has reached `start_print` with `end_print`.
- A path that reaches a printer or reads a roll says what it asked for and how it ended, through the `trace` service. The log and its routes are [docs/subsystems/trace.md](docs/subsystems/trace.md).
- **Never start a server with `&`; it outlives you.** Run a command against a throwaway server with `tools/with-server.sh`, and look at the page with `make drive`. The server dies when its launcher ends: the kernel kills it on Linux, and it watches for its parent on macOS. [docs/development.md](docs/development.md#throwaway-servers).
- **Run `make trace-test` before guessing.** It builds, runs the page once, prints the trace both sides wrote and fails if a declared step is missing. This is enforced, not advised: `make protocol-test` checks the protocol without a browser, so a step that runs without recording itself fails `make test` and names the line to add. Nothing depends on remembering.
- Preview and print share `compose` in `src/server.zig`. The page does not send its own preview pixels for a field label.
- The listener binds `127.0.0.1` only. Every route requires the session token, as `?token=` or the `niimbench` cookie. `GET /?token=` redirects to `/`.
- `docs/reviews/cordis-review.md` is the checklist for the plugin model. It is a copy of a review checklist from another project, not a niimbench status report.
- A user-visible change adds a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md). Releases are tag-driven: [docs/cookbook/releasing.md](docs/cookbook/releasing.md).
- **Keep the docs current.** A change to what someone sees, runs, sends or reads updates every page that describes it, in the same PR: the owning page, the user guide for the editor, the README for models and commands, and `docs/assets/editor.png` when the header or a panel changes. Before the PR, grep `README.md` and `docs/` for each name you changed. One fact, one home: [docs/AGENTS.md](docs/AGENTS.md).
- Text is drawn from the fonts in `src/fonts/`. A new font is an `embed` line in `src/font.zig`, its file and licence in `src/fonts/`, and a row in [src/fonts/README.md](src/fonts/README.md); `make test` then draws every letter of it. [docs/subsystems/text.md](docs/subsystems/text.md).
- `make lint` fails on a name the page script uses but nothing declares, on a relative doc link that does not resolve, and on another project named outside the README's one credit line.
- Describe current behavior. Do not invent a Chinese pair, a generated catalog, or a doc-budget script to imitate DeepSeek Harness.

## Editing these instructions

[CLAUDE.md](CLAUDE.md) points here. Keep each rule one to three lines and link its home. Stories and procedures belong in `docs/`, not in this file.
