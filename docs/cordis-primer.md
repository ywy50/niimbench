# Cordis primer

This file is the niimbench reading of Cordis. The language here is Zig. The model is the one in [A Programming Paradigm for Spatiotemporal Composability](https://arxiv.org/abs/2608.25512) and the [DeepSeek Harness primer](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer). `src/cordis.zig` is that model, small enough to boot this process. It is not the TypeScript package from [cordiverse/cordis](https://github.com/cordiverse/cordis).

## Five ideas

- A plugin is `name`, `inject`, and `apply(ctx)`. There is no second export shape.
- A context is the service map. Other plugins look up `ctx.get("printer")` and do not import a live instance.
- `inject` is the coeffect list. `mount` leaves the fiber inactive while a named service is absent, then `reconcile` applies it when the service appears. Removing the service drops the dependents.
- Events are `ctx.on` and `ctx.emit`. `print/done` is the print event.
- Every `ctx.set`, `ctx.on`, and manual `ctx.effect` pushes an inverse. `Fiber.dispose` and coeffect loss run those inverses last-in, first-out, and each inverse runs once.

## Names

| Paper / Cordis | niimbench |
|---|---|
| context | `*cordis.Context` |
| revertible effect | `ctx.effect`, `ctx.set`, `ctx.on` |
| coeffect declaration | `Plugin.inject` |
| coeffect read | `ctx.get` / `ctx.require` |
| provide | `ctx.set(key, ptr, destroy)` |
| component | `Plugin.apply` |
| fiber | return value of `ctx.mount` |
| loader row | one entry in `cordis.patch.yml` |

`ctx.set` takes a destroy function because the Zig service is a pointer, not a language object with a destructor. Destroy runs from the inverse, after dependents have dropped.

## What is not in this kernel

Hot reload of Zig code, realms, and the Cordis loader expression language are not implemented. The patch file is a list of `id`, `plugin`, and `inject`. Configuration that the process needs at boot, such as the HTTP port, is a field on the context set by `main` before `load`.

Bytes written to a printer cannot be un-written. The print path says so at `end_print`: that call is the compensation, not an inverse of the raster.

The review checklist for this model is [reviews/cordis-review.md](reviews/cordis-review.md).
