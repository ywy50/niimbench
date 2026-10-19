# Adding a plugin

1. Write `apply` in `src/plugins.zig` (or a file it imports). The function receives `*cordis.Context` and returns an error union.
2. Declare `inject` as the service keys you `require`. Do not `require` a key you did not list.
3. Publish anything other plugins should see with `ctx.set(key, ptr, destroy)`. `destroy` frees `ptr`.
4. Register listeners and registry rows with `ctx.on` or `ctx.effect`. The inverse runs on `dispose` and when a coeffect disappears.
5. Add a `cordis.Plugin` entry to `plugins.catalog`.
6. Add the same `id`, `plugin`, and `inject` to `src/default.patch.yml` and `cordis.patch.yml`.
7. Add a test that mounts the plugin, checks the service or route, disposes the fiber, and checks that the contribution is gone.

```zig
const record = "{\"title\":\"Niimbench\",\"sku\":\"NB-1\"}";

const Mark = struct {
    sources: *server.Sources,
    name: []const u8,
};

fn removeRecord(state: *anyopaque) void {
    const mark: *Mark = @ptrCast(@alignCast(state));
    if (mark.sources.remove(mark.name)) |entry| entry.free(mark.sources.allocator);
    mark.sources.allocator.free(mark.name);
    mark.sources.allocator.destroy(mark);
}

pub fn applyExampleSource(ctx: *cordis.Context) !void {
    const sources = ctx.require(server.Sources, "sources");
    try server.requireJsonObject(ctx.allocator, record);
    try sources.add("example", record);
    const mark = try ctx.allocator.create(Mark);
    errdefer ctx.allocator.destroy(mark);
    mark.* = .{ .sources = sources, .name = try ctx.allocator.dupe(u8, "example") };
    errdefer ctx.allocator.free(mark.name);
    try ctx.effect(removeRecord, mark);
}
```

`src/example_source.zig` is that plugin, complete, including its tests. `Sources.add` copies the name and the body; `Sources.remove` frees what the registry holds. The mark keeps its own copy of the name so the row can still be deleted after the plugin that added it is gone. `Sources.addOwned` skips the copies when the caller built the strings itself.

Do not start the listener or open the printer inside `apply`. Those are process-lifetime and hardware effects. `runServe` in `src/root.zig` calls `server.serve` after every fiber that can apply has applied.

If `apply` returns an error, the kernel drops effects registered so far and leaves the fiber inactive.

## A plugin that only adds a route

A route is an effect like any other. `addRoute` pushes the inverse onto the calling fiber:

```zig
pub fn applyBench(ctx: *cordis.Context) !void {
    const http = ctx.require(server.HttpService, "http");
    try server.addRoute(http, .GET, "/api/bench", bench);
}
```

`inject` gains `"http"`. Disposing the fiber removes the route, and nothing else has to know the route existed.
