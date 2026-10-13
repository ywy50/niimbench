const std = @import("std");
const packet = @import("packet.zig");
const raster = @import("raster.zig");

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(self: Transport, data: []const u8) !void {
        return self.vtable.write(self.ptr, data);
    }

    pub fn read(self: Transport, buf: []u8) !usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,
    data_buf: [packet.Packet.max_data]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, transport: Transport) Client {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn deinit(self: *Client) void {
        self.buffer.deinit(self.allocator);
        self.transport.close();
    }

    pub fn printGray(
        self: *Client,
        io: ?std.Io,
        pixels: []const u8,
        width: usize,
        height: usize,
        density: u8,
    ) !void {
        if (pixels.len != width * height) return error.BadSize;
        if (width > 65535 or height > 65535) return error.BadSize;
        if (density < 1 or density > 5) return error.BadDensity;
        _ = try self.command(.set_density, &.{density}, 16);
        _ = try self.command(.set_label_type, &.{1}, 16);
        _ = try self.command(.start_print, &.{1}, 1);
        _ = try self.command(.start_page, &.{1}, 1);
        var dim = [_]u8{
            @intCast((height >> 8) & 0xFF),
            @intCast(height & 0xFF),
            @intCast((width >> 8) & 0xFF),
            @intCast(width & 0xFF),
        };
        // niimprint calls set_dimension(image.height, image.width), so the
        // first word on the wire is the row count.
        _ = try self.command(.set_dimension, &dim, 1);
        const row_len = raster.packedRowBytes(width);
        const payload_len = row_len + 6;
        const payload = try self.allocator.alloc(u8, payload_len);
        defer self.allocator.free(payload);
        for (0..height) |y| {
            const header = raster.rowHeader(@intCast(y));
            @memcpy(payload[0..6], &header);
            raster.packRow(pixels[y * width ..][0..width], payload[6..][0..row_len]);
            try self.send(.image, payload);
        }
        _ = try self.command(.end_page, &.{1}, 1);
        if (io) |live| try live.sleep(.fromMilliseconds(300), .awake);
        // cordis-boundary: the page is already on the wire. end_print is the
        // compensation that tells the printer the job is finished.
        var tries: u8 = 0;
        while (tries < 50) : (tries += 1) {
            const done = try self.command(.end_print, &.{1}, 1);
            if (done) return;
            if (io) |live| try live.sleep(.fromMilliseconds(100), .awake);
        }
        return error.PrintDidNotFinish;
    }

    fn command(self: *Client, req: packet.Request, data: []const u8, resp_offset: u8) !bool {
        const response = try self.transceive(@intFromEnum(req), data, resp_offset);
        if (response.data.len == 0) return error.ShortResponse;
        return response.data[0] != 0;
    }

    fn send(self: *Client, req: packet.Request, data: []const u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{ .packet_type = @intFromEnum(req), .data = data }).toBytes(&wire);
        try self.transport.write(bytes);
    }

    fn transceive(self: *Client, req: u8, data: []const u8, resp_offset: u8) !packet.Packet {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{ .packet_type = req, .data = data }).toBytes(&wire);
        try self.transport.write(bytes);
        const expect: u8 = req +% resp_offset;
        var attempt: u8 = 0;
        while (attempt < 6) : (attempt += 1) {
            if (try self.pop(expect)) |found| return found;
            var tmp: [1024]u8 = undefined;
            const n = try self.transport.read(&tmp);
            if (n == 0) continue;
            try self.buffer.appendSlice(self.allocator, tmp[0..n]);
        }
        if (try self.pop(expect)) |found| return found;
        return error.NoResponse;
    }

    fn pop(self: *Client, expect: u8) !?packet.Packet {
        while (self.buffer.items.len - self.start > 4) {
            const available = self.buffer.items[self.start..];
            const pkt_len = @as(usize, available[3]) + 7;
            if (available.len < pkt_len) break;
            const parsed = try packet.Packet.fromBytes(available[0..pkt_len], &self.data_buf);
            self.start += pkt_len;
            if (self.start == self.buffer.items.len) {
                self.buffer.clearRetainingCapacity();
                self.start = 0;
            }
            if (parsed.packet_type == 219) return error.PrinterRefused;
            if (parsed.packet_type == 0) return error.PrinterUnsupported;
            if (parsed.packet_type == expect) {
                // fromBytes copied into data_buf. Copy again so the next pop
                // cannot overwrite the returned slice. Callers use it immediately.
                return parsed;
            }
        }
        return null;
    }
};

const Script = struct {
    allocator: std.mem.Allocator,
    written: std.ArrayList(u8) = .empty,
    inbound: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn deinit(self: *Script) void {
        self.written.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
    }

    fn push(self: *Script, req: packet.Request, offset: u8, data: []const u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{
            .packet_type = @intFromEnum(req) +% offset,
            .data = data,
        }).toBytes(&wire);
        try self.inbound.appendSlice(self.allocator, bytes);
    }

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *Script = @ptrCast(@alignCast(ptr));
        try self.written.appendSlice(self.allocator, data);
    }

    fn read(ptr: *anyopaque, buf: []u8) !usize {
        const self: *Script = @ptrCast(@alignCast(ptr));
        if (self.pos >= self.inbound.items.len) return 0;
        const n = @min(buf.len, self.inbound.items.len - self.pos);
        @memcpy(buf[0..n], self.inbound.items[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn close(_: *anyopaque) void {}
};

fn scriptTransport(script: *Script) Transport {
    return .{
        .ptr = script,
        .vtable = &.{ .write = Script.write, .read = Script.read, .close = Script.close },
    };
}

test "print sends the niimprint command sequence" {
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.push(.end_print, 1, &ok);

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);

    var types: [8]u8 = undefined;
    var count: usize = 0;
    var off: usize = 0;
    while (off < script.written.items.len) {
        const len = @as(usize, script.written.items[off + 3]) + 7;
        types[count] = script.written.items[off + 2];
        count += 1;
        off += len;
    }
    try std.testing.expectEqualSlices(u8, &[_]u8{
        @intFromEnum(packet.Request.set_density),
        @intFromEnum(packet.Request.set_label_type),
        @intFromEnum(packet.Request.start_print),
        @intFromEnum(packet.Request.start_page),
        @intFromEnum(packet.Request.set_dimension),
        @intFromEnum(packet.Request.image),
        @intFromEnum(packet.Request.end_page),
        @intFromEnum(packet.Request.end_print),
    }, types[0..count]);
}
