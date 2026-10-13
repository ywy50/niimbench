# Agents

Read [docs/architecture.md](docs/architecture.md) before changing plugins, and [docs/cordis-primer.md](docs/cordis-primer.md) before adding one.

- New behavior is a plugin with `name`, `inject`, and `apply`. Register it in `src/plugins.zig` and in both patch files.
- Publish services with `ctx.set` and listen with `ctx.on`. Both are effects. A `dispose` test must show the registration is gone.
- Do not keep a second registry in a module global. The context is the registry.
- Printer bytes on the wire are outside the effect system. Say so next to the send, and compensate with `end_print` when a job fails after `start_print`.
- `docs/reviews/cordis-review.md` is the checklist for that model. It is a copy of a review checklist from another project, not a niimbench status report.

Build and test with Zig 0.17: `zig build test`.
