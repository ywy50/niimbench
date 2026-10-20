const std = @import("std");
const raster = @import("raster.zig");

/// How a found device is reached. The transports registry opens the same two.
pub const Conn = enum {
    usb,
    bluetooth,

    pub fn name(self: Conn) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Conn {
        inline for (@typeInfo(Conn).@"enum".field_names) |field_name| {
            if (std.mem.eql(u8, text, field_name)) return @field(Conn, field_name);
        }
        return null;
    }
};

pub const max_devices = 16;
pub const max_addr = 128;
pub const max_name = 64;

/// One printer a scan confirmed. The strings live inline, so a found list owns
/// everything it reports and the next scan cannot leave a name behind.
pub const Device = struct {
    conn: Conn,
    /// The model id the printer answered with. 0 when the scan did not ask.
    model_id: u16 = 0,
    /// Null when the id or the name is not a head this bench knows.
    model: ?raster.Model = null,
    /// The device advertises the Bluetooth Serial Port Profile, which is what
    /// the RFCOMM transport connects to. False for USB.
    spp: bool = false,
    /// The device advertises the Niimbot BLE print service. A printer with this
    /// and no `spp` is BLE-only, such as the D110, and is printed over GATT.
    le: bool = false,
    addr_buf: [max_addr]u8 = undefined,
    addr_len: usize = 0,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,

    pub fn addr(self: *const Device) []const u8 {
        return self.addr_buf[0..self.addr_len];
    }

    pub fn name(self: *const Device) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The devices one scan found, in the order the transports reported them. A
/// fixed array rather than a list because this is a handful of nearby printers,
/// not a registry that grows while the process runs.
pub const Found = struct {
    items: [max_devices]Device = undefined,
    len: usize = 0,

    pub fn slice(self: *const Found) []const Device {
        return self.items[0..self.len];
    }

    pub fn clear(self: *Found) void {
        self.len = 0;
    }

    /// True when the same endpoint is already listed. Two transports cannot
    /// report the same address, but a repeated scan can.
    pub fn has(self: *const Found, conn: Conn, addr: []const u8) bool {
        for (self.slice()) |*device| {
            if (device.conn == conn and std.mem.eql(u8, device.addr(), addr)) return true;
        }
        return false;
    }

    /// Copy one found device into the list. A duplicate is not an error: the
    /// caller asks `has` first when it cares.
    pub fn add(self: *Found, conn: Conn, addr: []const u8, name: []const u8, model: ?raster.Model, model_id: u16, spp: bool) !void {
        return self.addBearer(conn, addr, name, model, model_id, .{ .spp = spp });
    }

    pub const Bearer = struct { spp: bool = false, le: bool = false };

    pub fn addBearer(self: *Found, conn: Conn, addr: []const u8, name: []const u8, model: ?raster.Model, model_id: u16, bearer: Bearer) !void {
        if (self.len == max_devices) return error.TooManyDevices;
        if (addr.len > max_addr or name.len > max_name) return error.NameTooLong;
        const device = &self.items[self.len];
        device.* = .{ .conn = conn, .model = model, .model_id = model_id, .spp = bearer.spp, .le = bearer.le };
        @memcpy(device.addr_buf[0..addr.len], addr);
        device.addr_len = addr.len;
        @memcpy(device.name_buf[0..name.len], name);
        device.name_len = name.len;
        self.len += 1;
    }

    /// Add a Bluetooth device if its name says it is a Niimbot printer. The
    /// name is the only model signal Bluetooth offers without connecting, so a
    /// name that carries a model word or the brand is kept and any other is
    /// skipped. A repeated address is the same device.
    pub fn addNamed(self: *Found, addr: []const u8, name: []const u8, bearer: Bearer) void {
        const model = modelForName(name);
        if (model == null and !mentionsNiimbot(name)) return;
        if (self.has(.bluetooth, addr)) return;
        self.addBearer(.bluetooth, addr, name, model, 0, bearer) catch {};
    }
};

/// The model behind a `PrinterInfo` (0x40) answer for key `0x08` (model id).
/// These are the 203 dpi heads this bench prints to. A 300 dpi Pro or D11_H
/// reports an id that is not here, which is how a caller tells them apart.
pub fn modelForId(id: u16) ?raster.Model {
    return switch (id) {
        768, 769, 771, 775, 776, 777 => .b21,
        4096, 4098 => .b1,
        3584, 3585 => .b18,
        512, 513, 514 => .d11,
        2304, 2305 => .d110,
        2320 => .d110_m,
        else => null,
    };
}

/// The model a Bluetooth name carries, such as `NIIMBOT B21` or `NIIMBOT-D110`.
/// Whole words only, so `b1` is not read out of `b18`, and a trailing `s` is
/// the same head (`B21S`, `D11S`). A name that says `pro` is a 300 dpi head
/// this bench does not print to, so the whole name resolves to null.
pub fn modelForName(name: []const u8) ?raster.Model {
    var it = std.mem.tokenizeAny(u8, name, " \t\r\n-_./,");
    var model: ?raster.Model = null;
    while (it.next()) |raw| {
        var word: [16]u8 = undefined;
        if (raw.len > word.len) continue;
        for (raw, 0..) |c, i| word[i] = std.ascii.toLower(c);
        var token = word[0..raw.len];
        if (token.len > 1 and token[token.len - 1] == 's') token = token[0 .. token.len - 1];
        if (std.mem.eql(u8, token, "pro")) return null;
        if (model != null) continue;
        if (std.mem.eql(u8, token, "b1")) {
            model = .b1;
        } else if (std.mem.eql(u8, token, "b18")) {
            model = .b18;
        } else if (std.mem.eql(u8, token, "b21")) {
            model = .b21;
        } else if (std.mem.eql(u8, token, "d11")) {
            model = .d11;
        } else if (std.mem.eql(u8, token, "d110")) {
            // A D110_M names itself `D110_M-` and its serial.
            const next = it.peek() orelse "";
            model = if (std.ascii.eqlIgnoreCase(next, "m")) .d110_m else .d110;
        }
    }
    return model;
}

/// True when the name carries the brand, whatever the case. A Bluetooth name is
/// the only model signal there is without connecting, so the brand word is a
/// second way in for a printer whose name has no model in it.
pub fn mentionsNiimbot(name: []const u8) bool {
    if (name.len < "niimbot".len) return false;
    var i: usize = 0;
    while (i + "niimbot".len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i..][0.."niimbot".len], "niimbot")) return true;
    }
    return false;
}

/// A transport's scan. `discover` asks for an active inquiry, which only the
/// Bluetooth finder can do; the serial finder probes the ports either way. The
/// allocator is the service's, because a finder may have to build a message.
pub const Finder = *const fn (io: std.Io, allocator: std.mem.Allocator, discover: bool, out: *Found) anyerror!void;

/// What the `devices` plugin publishes and `serial` and `bluetooth` fill in.
/// It holds the last scan as well as the finders, because "what is nearby" is
/// one fact and the page asks for it again every time it loads.
pub const Registry = struct {
    usb: ?Finder = null,
    bluetooth: ?Finder = null,
    found: Found = .{},
    scanned: bool = false,

    /// The first finder that failed the last scan, for the answer's `error`
    /// line. Both are static names — `@errorName` points into the compiler's
    /// tables — so there is nothing to free.
    failed_conn: ?[]const u8 = null,
    failed_error: ?[]const u8 = null,

    /// Replace `found` with what every installed finder reports. One transport
    /// failing must not hide what the other found, so the finding is kept and
    /// the first finding error is named in `failed_*` for the answer and the
    /// trace, rather than dropped.
    pub fn scan(self: *Registry, io: std.Io, allocator: std.mem.Allocator, discover: bool) void {
        self.found.clear();
        self.failed_conn = null;
        self.failed_error = null;
        if (self.usb) |find| find(io, allocator, discover, &self.found) catch |err| self.recordFailure("usb", err);
        if (self.bluetooth) |find| find(io, allocator, discover, &self.found) catch |err| self.recordFailure("bluetooth", err);
        self.scanned = true;
    }

    fn recordFailure(self: *Registry, conn: []const u8, err: anyerror) void {
        if (self.failed_error != null) return;
        self.failed_conn = conn;
        self.failed_error = @errorName(err);
    }
};

test "a printer model id is the head this bench prints to" {
    try std.testing.expectEqual(raster.Model.b21, modelForId(768).?);
    try std.testing.expectEqual(raster.Model.d11, modelForId(512).?);
    try std.testing.expectEqual(raster.Model.d110, modelForId(2304).?);
    try std.testing.expectEqual(raster.Model.d110_m, modelForId(2320).?);
    try std.testing.expectEqual(raster.Model.b1, modelForId(4096).?);
    try std.testing.expectEqual(raster.Model.b18, modelForId(3584).?);
    // A 300 dpi Pro head is not one of the five.
    try std.testing.expect(modelForId(785) == null);
    try std.testing.expect(modelForId(0) == null);
}

test "a device name resolves whole model words only" {
    try std.testing.expectEqual(raster.Model.b21, modelForName("NIIMBOT B21").?);
    try std.testing.expectEqual(raster.Model.d110, modelForName("NIIMBOT-D110").?);
    try std.testing.expectEqual(raster.Model.d110_m, modelForName("D110_M-I704252064").?);
    try std.testing.expectEqual(raster.Model.b18, modelForName("niimbot_b18").?);
    try std.testing.expectEqual(raster.Model.d11, modelForName("NIIMBOT D11S").?);
    try std.testing.expectEqual(raster.Model.b21, modelForName("B21S_C2B").?);
    // `b18` must not answer for `b1`, and a Pro is a different head.
    try std.testing.expectEqual(raster.Model.b18, modelForName("B18").?);
    try std.testing.expect(modelForName("NIIMBOT B1 PRO") == null);
    try std.testing.expect(modelForName("Speaker") == null);
    try std.testing.expect(modelForName("") == null);
}

test "a found list owns its strings and keeps a duplicate out by asking" {
    var found = Found{};
    try found.add(.usb, "/dev/ttyACM0", "NIIMBOT B21", .b21, 768, false);
    try found.add(.bluetooth, "AA:BB:CC:DD:EE:FF", "NIIMBOT D110", .d110, 2304, true);
    try std.testing.expectEqual(@as(usize, 2), found.slice().len);
    try std.testing.expectEqualStrings("/dev/ttyACM0", found.items[0].addr());
    try std.testing.expectEqualStrings("NIIMBOT D110", found.items[1].name());
    try std.testing.expect(found.has(.usb, "/dev/ttyACM0"));
    try std.testing.expect(!found.has(.bluetooth, "/dev/ttyACM0"));

    found.clear();
    try std.testing.expectEqual(@as(usize, 0), found.slice().len);
    try std.testing.expect(!found.has(.usb, "/dev/ttyACM0"));
}

test "connection names round trip" {
    try std.testing.expectEqualStrings("bluetooth", Conn.bluetooth.name());
    try std.testing.expectEqual(Conn.usb, Conn.parse("usb").?);
    try std.testing.expect(Conn.parse("serial") == null);
}
