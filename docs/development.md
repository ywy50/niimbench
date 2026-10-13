# Development

Zig 0.17. From the repository root:

```bash
zig build test
zig build run -- --port 8080 --no-open
zig build run -- print --image label.pgm --addr /dev/ttyACM0
```

`label.pgm` is a binary P5 file: `P5`, width, height, maxval `255`, then one byte per pixel. `0` is black and `255` is white.

## Boot list

`src/default.patch.yml` is compiled into the binary. `cordis.patch.yml` at the root is the same list and, when you run from this directory, replaces the embedded copy. Edit both, and keep `inject` identical to the `Plugin.inject` slice in `src/plugins.zig`. A mismatch is `error.InjectMismatch`.

## Process lifetime

`main` builds a context on the general-purpose allocator, loads the patch, and either serves HTTP or prints one image. `ctx.deinit` disposes fibers from last to first.

The HTTP listener and the bytes sent to the printer are process effects. They are not Cordis effects. Stopping the process closes the listener. A print that has already reached `start_print` finishes with `end_print`.

## Docs map

This tree follows the DeepSeek Harness docs layout, scoped to niimbench:

| Harness | niimbench |
|---|---|
| `docs/architecture.md` | [architecture.md](architecture.md) |
| `docs/cordis-primer.md` | [cordis-primer.md](cordis-primer.md) |
| `docs/development.md` | this file |
| `docs/glossary.md` | [glossary.md](glossary.md) |
| `docs/testing.md` | [testing.md](testing.md) |
| `docs/subsystems/` | [subsystems/](subsystems/) |
| `docs/cookbook/` | [cookbook/adding-a-plugin.md](cookbook/adding-a-plugin.md) |
| reviews | [reviews/](reviews/) |
