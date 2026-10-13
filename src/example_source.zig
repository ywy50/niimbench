const std = @import("std");
const cordis = @import("cordis.zig");
const server = @import("server.zig");

/// A flat record the editor can fill fields from. Keys are what `Field.key`
/// looks up, so the shape is fixed by this plugin, not by the source registry.
pub const record = "{\"title\":\"Niimbench\",\"sku\":\"NB-1\"}";

const Mark = struct {
    sources: *server.Sources,
    name: []const u8,
};

fn removeRecord(state: *anyopaque) void {
    const mark: *Mark = @ptrCast(@alignCast(state));
    // The registry hands back the strings it was holding; the mark's `name`
    // is a separate copy that this plugin owns.
    if (mark.sources.remove(mark.name)) |entry| entry.free(mark.sources.allocator);
    mark.sources.allocator.free(mark.name);
    mark.sources.allocator.destroy(mark);
}

/// Publishes the record `example` into the `sources` registry. The registry
/// takes its own copies, so this plugin only owns the mark that names the row
/// it must delete on unload.
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

const sources_plugin: cordis.Plugin = .{
    .name = "json-source",
    .inject = &.{"sources"},
    .apply = applyExampleSource,
};

test "the example source is registered and unregistered with its fiber" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = server.applySources });
    const fiber = try ctx.mount("json-source", sources_plugin);
    const sources = ctx.require(server.Sources, "sources");
    try std.testing.expectEqual(@as(usize, 1), sources.names.items.len);
    try std.testing.expectEqualStrings(record, sources.find("example").?);

    fiber.dispose();
    try std.testing.expect(sources.find("example") == null);
    try std.testing.expectEqual(@as(usize, 0), sources.names.items.len);
    try std.testing.expectEqual(@as(usize, 0), sources.bodies.items.len);
}

test "the example record is a flat object with the documented keys" {
    const gpa = std.testing.allocator;
    try server.requireJsonObject(gpa, record);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, record, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("title") != null);
    try std.testing.expect(parsed.value.object.get("sku") != null);
}
