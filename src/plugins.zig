const std = @import("std");
const cordis = @import("cordis.zig");
const device = @import("device.zig");
const server = @import("server.zig");

const example_record = "{\"title\":\"Niimbench\",\"sku\":\"NB-1\"}";

const OpenerSlot = struct {
    const Kind = enum { usb, bluetooth };
    allocator: std.mem.Allocator,
    registry: *device.Registry,
    kind: Kind,
};

fn clearOpener(state: *anyopaque) void {
    const slot: *OpenerSlot = @ptrCast(@alignCast(state));
    switch (slot.kind) {
        .usb => slot.registry.usb = null,
        .bluetooth => slot.registry.bluetooth = null,
    }
    slot.allocator.destroy(slot);
}

fn trackOpener(ctx: *cordis.Context, registry: *device.Registry, kind: OpenerSlot.Kind) !void {
    const slot = try ctx.allocator.create(OpenerSlot);
    slot.* = .{ .allocator = ctx.allocator, .registry = registry, .kind = kind };
    try ctx.effect(clearOpener, slot);
}

pub fn applySerial(ctx: *cordis.Context) !void {
    const registry = ctx.require(device.Registry, "transports");
    registry.usb = device.openSerial;
    try trackOpener(ctx, registry, .usb);
}

pub fn applyBluetooth(ctx: *cordis.Context) !void {
    const registry = ctx.require(device.Registry, "transports");
    registry.bluetooth = device.openBluetooth;
    try trackOpener(ctx, registry, .bluetooth);
}

const SourceState = struct {
    sources: *server.Sources,
    name: []const u8,
};

fn removeSource(state: *anyopaque) void {
    const mark: *SourceState = @ptrCast(@alignCast(state));
    mark.sources.remove(mark.name);
    mark.sources.allocator.destroy(mark);
}

pub fn applyJsonSource(ctx: *cordis.Context) !void {
    const sources = ctx.require(server.Sources, "sources");
    try sources.add("example", example_record);
    const mark = try ctx.allocator.create(SourceState);
    mark.* = .{ .sources = sources, .name = "example" };
    try ctx.effect(removeSource, mark);
}

pub const catalog = [_]cordis.Plugin{
    .{ .name = "printer", .apply = server.applyPrinter },
    .{ .name = "transports", .apply = server.applyTransports },
    .{ .name = "serial", .inject = &.{"transports"}, .apply = applySerial },
    .{ .name = "bluetooth", .inject = &.{"transports"}, .apply = applyBluetooth },
    .{ .name = "sources", .apply = server.applySources },
    .{ .name = "json-source", .inject = &.{"sources"}, .apply = applyJsonSource },
    .{ .name = "http", .inject = &.{ "printer", "transports", "sources" }, .apply = server.applyHttp },
    .{ .name = "editor", .inject = &.{"http"}, .apply = server.applyEditor },
};

pub fn find(name: []const u8) ?cordis.Plugin {
    for (catalog) |plugin| {
        if (std.mem.eql(u8, plugin.name, name)) return plugin;
    }
    return null;
}

test "serial registration is reverted when the fiber drops" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    const serial = try ctx.mount("serial", .{ .name = "serial", .inject = &.{"transports"}, .apply = applySerial });
    const registry = ctx.require(device.Registry, "transports");
    try std.testing.expect(registry.usb != null);
    serial.dispose();
    try std.testing.expect(registry.usb == null);
}
