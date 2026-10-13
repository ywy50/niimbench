const std = @import("std");
const cordis = @import("cordis.zig");
const patch = @import("patch.zig");
const plugins = @import("plugins.zig");

pub const bundled_patch = @embedFile("default.patch.yml");

pub fn loadText(ctx: *cordis.Context, text: []const u8) !void {
    const rows = try patch.parse(ctx.allocator, text);
    defer patch.freeRows(ctx.allocator, rows);
    for (rows) |row| {
        const plugin = plugins.find(row.plugin) orelse return error.UnknownPlugin;
        if (!sameInject(plugin.inject, row.inject)) return error.InjectMismatch;
        _ = try ctx.mount(row.id, plugin);
    }
}

fn sameInject(declared: []const []const u8, written: []const []const u8) bool {
    if (declared.len != written.len) return false;
    for (declared, written) |want, got| {
        if (!std.mem.eql(u8, want, got)) return false;
    }
    return true;
}

pub fn loadDefault(ctx: *cordis.Context, io: std.Io) !void {
    ctx.io = io;
    const override = readCwd(ctx.allocator, io, "cordis.patch.yml") catch null;
    defer if (override) |text| ctx.allocator.free(text);
    try loadText(ctx, override orelse bundled_patch);
}

fn readCwd(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(1 << 20));
}
