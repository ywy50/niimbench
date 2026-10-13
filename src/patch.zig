const std = @import("std");

pub const Row = struct {
    id: []const u8,
    plugin: []const u8,
    inject: []const []const u8,
};

/// Parses the small `cordis.patch.yml` subset used by this repo:
/// a list of maps with `id`, `plugin`, and an optional `inject: [a, b]`.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    errdefer {
        for (rows.items) |row| freeRow(allocator, row);
        rows.deinit(allocator);
    }
    var current: ?Row = null;
    errdefer if (current) |row| freeRow(allocator, row);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "- ")) {
            if (current) |row| {
                if (row.plugin.len == 0) return error.MissingPlugin;
                try rows.append(allocator, row);
                current = null;
            }
            const body = std.mem.trim(u8, line[2..], " ");
            const id = try field(allocator, body, "id") orelse return error.ExpectedId;
            current = .{ .id = id, .plugin = "", .inject = &.{} };
            continue;
        }
        var row = current orelse return error.OrphanField;
        if (try field(allocator, line, "plugin")) |plugin| {
            if (row.plugin.len != 0) allocator.free(row.plugin);
            row.plugin = plugin;
            current = row;
            continue;
        }
        if (std.mem.startsWith(u8, line, "inject:")) {
            const spec = std.mem.trim(u8, line["inject:".len..], " ");
            row.inject = try parseInject(allocator, spec);
            current = row;
            continue;
        }
        return error.UnknownField;
    }
    if (current) |row| {
        if (row.plugin.len == 0) return error.MissingPlugin;
        try rows.append(allocator, row);
    }
    return rows.toOwnedSlice(allocator);
}

pub fn freeRows(allocator: std.mem.Allocator, rows: []Row) void {
    for (rows) |row| freeRow(allocator, row);
    allocator.free(rows);
}

fn freeRow(allocator: std.mem.Allocator, row: Row) void {
    allocator.free(row.id);
    if (row.plugin.len != 0) allocator.free(row.plugin);
    for (row.inject) |key| allocator.free(key);
    if (row.inject.len != 0) allocator.free(row.inject);
}

fn field(allocator: std.mem.Allocator, line: []const u8, name: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, line, name)) return null;
    if (line.len < name.len + 1 or line[name.len] != ':') return null;
    const value = std.mem.trim(u8, line[name.len + 1 ..], " ");
    if (value.len == 0) return error.EmptyField;
    return try allocator.dupe(u8, value);
}

fn parseInject(allocator: std.mem.Allocator, spec: []const u8) ![]const []const u8 {
    if (spec.len < 2 or spec[0] != '[' or spec[spec.len - 1] != ']') return error.BadInject;
    const inner = std.mem.trim(u8, spec[1 .. spec.len - 1], " ");
    if (inner.len == 0) return &.{};
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    var parts = std.mem.splitScalar(u8, inner, ',');
    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " ");
        if (name.len == 0) return error.BadInject;
        try keys.append(allocator, try allocator.dupe(u8, name));
    }
    return keys.toOwnedSlice(allocator);
}

test "parse a plugin list" {
    const gpa = std.testing.allocator;
    const text =
        \\- id: printer
        \\  plugin: printer
        \\
        \\- id: http
        \\  plugin: http
        \\  inject: [printer, sources]
    ;
    const rows = try parse(gpa, text);
    defer freeRows(gpa, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("http", rows[1].id);
    try std.testing.expectEqual(@as(usize, 2), rows[1].inject.len);
    try std.testing.expectEqualStrings("sources", rows[1].inject[1]);
}
