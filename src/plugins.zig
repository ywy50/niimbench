const std = @import("std");
const cordis = @import("cordis.zig");
const device = @import("device.zig");
const discovery = @import("discovery.zig");
const example_source = @import("example_source.zig");
const label = @import("label.zig");
const packet = @import("packet.zig");
const printer_mod = @import("printer.zig");
const raster = @import("raster.zig");
const server = @import("server.zig");
const trace = @import("trace.zig");

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

const FinderSlot = struct {
    const Kind = enum { usb, bluetooth };
    allocator: std.mem.Allocator,
    registry: *discovery.Registry,
    kind: Kind,
};

fn clearFinder(state: *anyopaque) void {
    const slot: *FinderSlot = @ptrCast(@alignCast(state));
    switch (slot.kind) {
        .usb => slot.registry.usb = null,
        .bluetooth => slot.registry.bluetooth = null,
    }
    slot.allocator.destroy(slot);
}

fn trackFinder(ctx: *cordis.Context, registry: *discovery.Registry, kind: FinderSlot.Kind) !void {
    const slot = try ctx.allocator.create(FinderSlot);
    slot.* = .{ .allocator = ctx.allocator, .registry = registry, .kind = kind };
    try ctx.effect(clearFinder, slot);
}

pub fn applySerial(ctx: *cordis.Context) !void {
    const registry = ctx.require(device.Registry, "transports");
    registry.usb = device.openSerial;
    try trackOpener(ctx, registry, .usb);
    const devices = ctx.require(discovery.Registry, "devices");
    devices.usb = device.findSerial;
    try trackFinder(ctx, devices, .usb);
}

pub fn applyBluetooth(ctx: *cordis.Context) !void {
    const registry = ctx.require(device.Registry, "transports");
    registry.bluetooth = device.openBluetooth;
    try trackOpener(ctx, registry, .bluetooth);
    const devices = ctx.require(discovery.Registry, "devices");
    devices.bluetooth = device.findBluetooth;
    try trackFinder(ctx, devices, .bluetooth);
}

/// The example record lives in `example_source.zig` so the plugin that owns
/// it owns its registration and its inverse.
const json_source: cordis.Plugin = .{
    .name = "json-source",
    .inject = &.{"sources"},
    .apply = example_source.applyExampleSource,
};

pub const catalog = [_]cordis.Plugin{
    .{ .name = "trace", .apply = trace.applyTrace },
    .{ .name = "printer", .apply = server.applyPrinter },
    .{ .name = "transports", .apply = server.applyTransports },
    .{ .name = "devices", .apply = server.applyDevices },
    .{ .name = "serial", .inject = &.{ "transports", "devices" }, .apply = applySerial },
    .{ .name = "bluetooth", .inject = &.{ "transports", "devices" }, .apply = applyBluetooth },
    .{ .name = "sources", .apply = server.applySources },
    json_source,
    .{ .name = "http", .inject = &.{ "printer", "transports", "devices", "sources" }, .apply = server.applyHttp },
    .{ .name = "editor", .inject = &.{"http"}, .apply = server.applyEditor },
};

pub fn find(name: []const u8) ?cordis.Plugin {
    for (catalog) |plugin| {
        if (std.mem.eql(u8, plugin.name, name)) return plugin;
    }
    return null;
}

test "render route draws the installed source record" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = server.applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = server.applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = server.applySources });
    _ = try ctx.mount("json-source", json_source);
    _ = try ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "devices", "sources" },
        .apply = server.applyHttp,
    });
    const http = ctx.require(server.HttpService, "http");
    const source_json = http.sources.find("example").?;
    const direct = try label.render(gpa, 80, 24, &.{.{ .key = "sku", .x = 1, .y = 1, .size = 16 }}, source_json);
    defer gpa.free(direct.pixels);

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const body = "{\"width\":80,\"height\":24,\"source\":\"example\",\"fields\":[{\"key\":\"sku\",\"x\":1,\"y\":1,\"size\":16}]}";
    const response = try http.dispatch(.{
        .io = undefined,
        .method = .POST,
        .path = "/api/render",
        .query = query,
        .body = body,
    });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const Parsed = struct { width: usize, height: usize, pixels_b64: []const u8 };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, response.body, .{});
    defer parsed.deinit();
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(parsed.value.pixels_b64);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, parsed.value.pixels_b64);
    try std.testing.expectEqualSlices(u8, direct.pixels, decoded);

    const other = try http.dispatch(.{
        .io = undefined,
        .method = .POST,
        .path = "/api/render",
        .query = query,
        .body = "{\"width\":80,\"height\":24,\"source\":\"example\",\"fields\":[{\"key\":\"title\",\"x\":1,\"y\":1,\"size\":16}]}",
    });
    defer if (other.owned) gpa.free(other.body);
    try std.testing.expect(!std.mem.eql(u8, response.body, other.body));
}

test "printing a label reaches the transport with the rendered page" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = server.applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = server.applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = server.applySources });
    _ = try ctx.mount("json-source", json_source);
    _ = try ctx.mount("serial", .{ .name = "serial", .inject = &.{ "transports", "devices" }, .apply = applySerial });
    _ = try ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "sources" },
        .apply = server.applyHttp,
    });
    const http = ctx.require(server.HttpService, "http");
    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try http.dispatch(.{
        .io = undefined,
        .method = .POST,
        .path = "/api/print",
        .query = query,
        .body = "{\"width\":80,\"height\":16,\"source\":\"example\",\"fields\":[{\"key\":\"sku\",\"x\":1,\"y\":1}],\"conn\":\"usb\",\"addr\":\"/no/such/niimbench-tty\",\"model\":\"b21\"}",
    });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "FileNotFound") != null);
}

const Capture = struct {
    allocator: std.mem.Allocator,
    written: std.ArrayList(u8) = .empty,
    inbound: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn deinit(self: *Capture) void {
        self.written.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
    }

    fn pushOk(self: *Capture, req: packet.Request, offset: u8) !void {
        try self.push(req, offset, &.{1});
    }

    fn push(self: *Capture, req: packet.Request, offset: u8, data: []const u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{ .packet_type = @backingInt(req) +% offset, .data = data }).toBytes(&wire);
        try self.inbound.appendSlice(self.allocator, bytes);
    }

    fn pushPage(self: *Capture, page: u16, print_pct: u8, feed_pct: u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const data = [_]u8{
            @intCast((page >> 8) & 0xFF),
            @intCast(page & 0xFF),
            print_pct,
            feed_pct,
        };
        const bytes = try (packet.Packet{
            .packet_type = @backingInt(packet.Request.get_print_status) +% 16,
            .data = &data,
        }).toBytes(&wire);
        try self.inbound.appendSlice(self.allocator, bytes);
    }

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        try self.written.appendSlice(self.allocator, data);
    }

    fn read(ptr: *anyopaque, buf: []u8) !usize {
        const self: *Capture = @ptrCast(@alignCast(ptr));
        if (self.pos >= self.inbound.items.len) return 0;
        // One answer a read, as a printer gives them: handing over the whole
        // script let one job's client swallow the answers queued for the next.
        const rest = self.inbound.items[self.pos..];
        const frame = if (rest.len >= 4) @as(usize, rest[3]) + 7 else rest.len;
        const n = @min(buf.len, frame, rest.len);
        @memcpy(buf[0..n], rest[0..n]);
        self.pos += n;
        return n;
    }

    fn close(_: *anyopaque) void {}
};

var capture_for_open: ?*Capture = null;

fn openCapture(_: std.mem.Allocator, _: std.Io, _: []const u8) !printer_mod.Transport {
    const cap = capture_for_open orelse return error.NoCapture;
    return .{
        .ptr = cap,
        .vtable = &.{ .write = Capture.write, .read = Capture.read, .close = Capture.close },
    };
}

fn resetCapture(capture: *Capture) !void {
    capture.written.clearRetainingCapacity();
    capture.inbound.clearRetainingCapacity();
    capture.pos = 0;
    try pushJob(capture);
}

/// The answers a scripted printer gives to one job, queued after any already
/// there, so a test can script a second job.
fn pushJob(capture: *Capture) !void {
    // A D-series job asks the protocol first. 1 is protocol 0: the older
    // sequence. A B-series job never asks, and skips past this answer.
    try capture.pushOk(.connect, 1);
    try capture.pushOk(.set_density, 16);
    try capture.pushOk(.set_label_type, 16);
    try capture.pushOk(.start_print, 1);
    // A D-series client clears the page buffer before the page and sets one
    // copy after its size. A B-series client asks for neither, and skips
    // past these answers.
    try capture.pushOk(.allow_print_clear, 16);
    try capture.pushOk(.start_page, 1);
    try capture.pushOk(.set_dimension, 1);
    try capture.pushOk(.set_quantity, 1);
    try capture.pushOk(.end_page, 1);
    // The counter moves, then the job ends. A status stuck at 100% is a skip.
    try capture.pushPage(0, 0, 0);
    try capture.pushPage(1, 100, 100);
    try capture.pushOk(.end_print, 1);
}

/// The commands a job wrote, in order, without its row packets, and the
/// payload of its `PrintQuantity` if it sent one.
fn commandsWritten(capture: *Capture, out: []u8) struct { types: []const u8, quantity: ?[]const u8 } {
    var n: usize = 0;
    var quantity: ?[]const u8 = null;
    var off: usize = 0;
    while (off + 7 <= capture.written.items.len) {
        // `Connect` alone goes out behind a 0x03 prefix.
        if (capture.written.items[off] == 0x03) off += 1;
        const len = @as(usize, capture.written.items[off + 3]);
        const kind = capture.written.items[off + 2];
        if (kind != @backingInt(packet.Request.image) and kind != @backingInt(packet.Request.empty_row) and n < out.len) {
            out[n] = kind;
            n += 1;
        }
        if (kind == @backingInt(packet.Request.set_quantity)) quantity = capture.written.items[off + 4 .. off + 4 + len];
        off += len + 7;
    }
    return .{ .types = out[0..n], .quantity = quantity };
}

/// Expand the row packets the way the printer does, a blank run and a repeat
/// count included, and compare every row with the drawn page.
fn expectPackedRows(capture: *Capture, drawn: raster.Gray) !void {
    const row_len = raster.packedRowBytes(drawn.width);
    var off: usize = 0;
    var row: usize = 0;
    while (off + 7 <= capture.written.items.len) {
        // `Connect` alone goes out behind a 0x03 prefix.
        if (capture.written.items[off] == 0x03) off += 1;
        const pkt_len = @as(usize, capture.written.items[off + 3]) + 7;
        const kind = capture.written.items[off + 2];
        const payload = capture.written.items[off + 4 .. off + pkt_len];
        const blank = kind == @backingInt(packet.Request.empty_row);
        if (blank or kind == @backingInt(packet.Request.image)) {
            try std.testing.expectEqual(row, @as(usize, payload[0]) << 8 | payload[1]);
            const repeat: usize = if (blank) payload[2] else payload[5];
            for (0..repeat) |_| {
                var expect_row: [16]u8 = undefined;
                raster.packRow(drawn.pixels[row * drawn.width ..][0..drawn.width], expect_row[0..row_len]);
                if (blank) {
                    try std.testing.expect(std.mem.allEqual(u8, expect_row[0..row_len], 0));
                } else {
                    try std.testing.expectEqualSlices(u8, expect_row[0..row_len], payload[6..][0..row_len]);
                }
                row += 1;
            }
        }
        off += pkt_len;
    }
    try std.testing.expectEqual(drawn.height, row);
}

test "print sends the source text that render drew" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = server.applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = server.applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = server.applySources });
    _ = try ctx.mount("json-source", json_source);
    _ = try ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "devices", "sources" },
        .apply = server.applyHttp,
    });
    const http = ctx.require(server.HttpService, "http");
    const source_json = http.sources.find("example").?;
    const drawn = try label.render(gpa, 48, 8, &.{.{ .key = "sku", .x = 0, .y = 0, .size = 8 }}, source_json);
    defer gpa.free(drawn.pixels);

    var capture = Capture{ .allocator = gpa };
    defer capture.deinit();
    capture_for_open = &capture;
    defer capture_for_open = null;
    http.transports.usb = openCapture;
    http.transports.bluetooth = openCapture;

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    // Same rendered page leaves through both openers. A blank page fails the
    // compare against the source text, on USB and on Bluetooth.
    const conns = [_][]const u8{ "usb", "bluetooth" };
    for (conns) |conn| {
        try resetCapture(&capture);
        const body = try std.fmt.allocPrint(gpa,
            \\{{"width":48,"height":8,"source":"example","fields":[{{"key":"sku","x":0,"y":0,"size":8}}],"conn":"{s}","addr":"capture","model":"b21","density":3}}
        , .{conn});
        defer gpa.free(body);
        const response = try http.dispatch(.{
            .io = std.testing.io,
            .method = .POST,
            .path = "/api/print",
            .query = query,
            .body = body,
        });
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        try expectPackedRows(&capture, drawn);
        // The B-series sequence has no PrintClear and no PrintQuantity.
        var seen: [32]u8 = undefined;
        const job = commandsWritten(&capture, &seen);
        try std.testing.expect(std.mem.indexOfScalar(u8, job.types, 0x20) == null);
        try std.testing.expect(job.quantity == null);
    }
}

test "a D-series print leaves the page margin off the end of the label" {
    // The editor lays out on the whole 96x320 label, so its centre is the
    // paper's centre. The gap sensor needs the last 16 rows blank, so the
    // printer gets the first 304 rows of that page and nothing after them.
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = server.applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = server.applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = server.applySources });
    _ = try ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "devices", "sources" },
        .apply = server.applyHttp,
    });
    const http = ctx.require(server.HttpService, "http");
    const drawn = try label.render(gpa, 96, 320, &.{.{ .text = "X", .x = 40, .y = 150, .size = 16 }}, "");
    defer gpa.free(drawn.pixels);

    var capture = Capture{ .allocator = gpa };
    defer capture.deinit();
    capture_for_open = &capture;
    defer capture_for_open = null;
    http.transports.usb = openCapture;
    try resetCapture(&capture);

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try http.dispatch(.{
        .io = std.testing.io,
        .method = .POST,
        .path = "/api/print",
        .query = query,
        .body = "{\"width\":96,\"height\":320,\"fields\":[{\"text\":\"X\",\"x\":40,\"y\":150,\"size\":16}],\"conn\":\"usb\",\"addr\":\"capture\",\"model\":\"d110\",\"density\":3}",
    });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try expectPackedRows(&capture, .{ .pixels = drawn.pixels[0 .. 96 * 304], .width = 96, .height = 304 });
    // One copy, from a cleared buffer: a D110_M left to its own count printed
    // a page twice after idle.
    var seen: [32]u8 = undefined;
    const job = commandsWritten(&capture, &seen);
    try std.testing.expectEqualSlices(u8, &.{ 0xC1, 0x21, 0x23, 0x01, 0x20, 0x03, 0x13, 0x15, 0xE3, 0xA3, 0xA3, 0xF3 }, job.types);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1 }, job.quantity orelse return error.NoQuantity);
}

test "serial registration is reverted when the fiber drops" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = server.applyDevices });
    const serial = try ctx.mount("serial", .{ .name = "serial", .inject = &.{ "transports", "devices" }, .apply = applySerial });
    const bluetooth = try ctx.mount("bluetooth", .{ .name = "bluetooth", .inject = &.{ "transports", "devices" }, .apply = applyBluetooth });
    const registry = ctx.require(device.Registry, "transports");
    const devices = ctx.require(discovery.Registry, "devices");
    try std.testing.expect(registry.usb != null);
    try std.testing.expect(registry.bluetooth != null);
    // A transport owns its opener and its finder, and dropping the fiber takes
    // both back out.
    try std.testing.expect(devices.usb != null);
    try std.testing.expect(devices.bluetooth != null);
    serial.dispose();
    try std.testing.expect(registry.usb == null);
    try std.testing.expect(registry.bluetooth != null);
    try std.testing.expect(devices.usb == null);
    try std.testing.expect(devices.bluetooth != null);
    bluetooth.dispose();
    try std.testing.expect(registry.bluetooth == null);
    try std.testing.expect(devices.bluetooth == null);
}

fn mountCaptured(ctx: *cordis.Context) !*server.HttpService {
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = server.applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = server.applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = server.applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = server.applySources });
    _ = try ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "devices", "sources" },
        .apply = server.applyHttp,
    });
    const http = ctx.require(server.HttpService, "http");
    http.transports.usb = openCapture;
    return http;
}

test "Set printer clock sends the page's local time in the form a D110_M takes" {
    // PrinterConfig2 as the protocol notes draw it: 1 (set), year 2026 as
    // 07 EA, then October 20, 00:12:05. A D110_M answers 01 01: the first
    // byte echoed, then 1 for done. Upstream's form puts item 8 first; a
    // D110_M answers that 08 00, refused, so it is the fallback.
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    const http = try mountCaptured(&ctx);
    var capture = Capture{ .allocator = gpa };
    defer capture.deinit();
    capture_for_open = &capture;
    defer capture_for_open = null;
    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const body = "{\"conn\":\"usb\",\"addr\":\"capture\",\"year\":2026,\"month\":10,\"day\":20,\"hour\":0,\"minute\":12,\"second\":5}";
    const short = [_]u8{ 0x55, 0x55, 0x07, 8, 1, 0x07, 0xEA, 10, 20, 0, 12, 5 };
    const long = [_]u8{ 0x55, 0x55, 0x07, 9, 8, 1, 0x07, 0xEA, 10, 20, 0, 12, 5 };

    // The short form is done: one frame, and the page hears ok.
    try capture.push(.printer_config2, 1, &.{ 1, 1 });
    {
        const response = try http.dispatch(.{ .io = std.testing.io, .method = .POST, .path = "/api/printer/clock", .query = query, .body = body });
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        try std.testing.expectEqualSlices(u8, &short, capture.written.items[0..short.len]);
        try std.testing.expectEqual(short.len + 3, capture.written.items.len);
    }
    // The short form refused, the long one done.
    capture.written.clearRetainingCapacity();
    try capture.push(.printer_config2, 1, &.{ 1, 0 });
    try capture.push(.printer_config2, 1, &.{ 8, 1 });
    {
        const response = try http.dispatch(.{ .io = std.testing.io, .method = .POST, .path = "/api/printer/clock", .query = query, .body = body });
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        try std.testing.expectEqualSlices(u8, &long, capture.written.items[short.len + 3 ..][0..long.len]);
    }
    // Both refused: the page hears ClockRefused, not "set". The echo in the
    // first byte used to read as done.
    capture.written.clearRetainingCapacity();
    try capture.push(.printer_config2, 1, &.{ 1, 0 });
    try capture.push(.printer_config2, 1, &.{ 8, 0 });
    {
        const response = try http.dispatch(.{ .io = std.testing.io, .method = .POST, .path = "/api/printer/clock", .query = query, .body = body });
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.bad_request, response.status);
        try std.testing.expect(std.mem.indexOf(u8, response.body, "ClockRefused") != null);
    }
    // A month 13 never reaches the printer.
    capture.written.clearRetainingCapacity();
    {
        const response = try http.dispatch(.{
            .io = std.testing.io,
            .method = .POST,
            .path = "/api/printer/clock",
            .query = query,
            .body = "{\"conn\":\"usb\",\"addr\":\"capture\",\"year\":2026,\"month\":13,\"day\":20,\"hour\":0,\"minute\":12,\"second\":5}",
        });
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.bad_request, response.status);
        try std.testing.expectEqual(@as(usize, 0), capture.written.items.len);
    }
}

test "copies on a B-series printer are the job sent once per copy" {
    // The B-series sequence has no copy count, so two copies are two jobs.
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    const http = try mountCaptured(&ctx);
    var capture = Capture{ .allocator = gpa };
    defer capture.deinit();
    capture_for_open = &capture;
    defer capture_for_open = null;
    try resetCapture(&capture);
    try pushJob(&capture);

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try http.dispatch(.{
        .io = std.testing.io,
        .method = .POST,
        .path = "/api/print",
        .query = query,
        .body = "{\"width\":48,\"height\":8,\"fields\":[{\"text\":\"X\",\"x\":0,\"y\":0,\"size\":8}],\"conn\":\"usb\",\"addr\":\"capture\",\"model\":\"b21\",\"density\":3,\"copies\":2}",
    });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    var seen: [64]u8 = undefined;
    const job = commandsWritten(&capture, &seen);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, job.types, &.{@backingInt(packet.Request.start_print)}));
    try std.testing.expect(job.quantity == null);

    // A hundred copies is refused before anything reaches the printer.
    const many = try http.dispatch(.{
        .io = std.testing.io,
        .method = .POST,
        .path = "/api/print",
        .query = query,
        .body = "{\"width\":48,\"height\":8,\"fields\":[{\"text\":\"X\",\"x\":0,\"y\":0,\"size\":8}],\"conn\":\"usb\",\"addr\":\"capture\",\"model\":\"b21\",\"density\":3,\"copies\":100}",
    });
    defer if (many.owned) gpa.free(many.body);
    try std.testing.expectEqual(std.http.Status.bad_request, many.status);
    try std.testing.expect(std.mem.indexOf(u8, many.body, "BadCopies") != null);
}
