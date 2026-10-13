# Adding a plugin

1. Write `apply` in `src/plugins.zig` (or a file it imports). The function receives `*cordis.Context` and returns an error union.
2. Declare `inject` as the service keys you `require`. Do not `require` a key you did not list.
3. Publish anything other plugins should see with `ctx.set(key, ptr, destroy)`. `destroy` frees `ptr`.
4. Register listeners and registry rows with `ctx.on` or `ctx.effect`. The inverse runs on `dispose` and when a coeffect disappears.
5. Add a `cordis.Plugin` entry to `plugins.catalog`.
6. Add the same `id`, `plugin`, and `inject` to `src/default.patch.yml` and `cordis.patch.yml`.
7. Add a test that mounts the plugin, checks the service or route, disposes the fiber, and checks that the contribution is gone.

```zig
pub fn applyExample(ctx: *cordis.Context) !void {
    const sources = ctx.require(server.Sources, "sources");
    try sources.add("sku", "{\"sku\":\"NB-1\"}");
    const mark = try ctx.allocator.create(SourceState);
    mark.* = .{ .sources = sources, .name = "sku" };
    try ctx.effect(removeSource, mark);
}
```

Do not start the listener or open the printer inside `apply`. Those are process-lifetime and hardware effects. `main` calls `server.serve` after every fiber that can apply has applied.

If `apply` returns an error, the kernel drops effects registered so far and leaves the fiber inactive.
