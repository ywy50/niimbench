const std = @import("std");
const dbus = @import("dbus.zig");
const printer = @import("printer.zig");

/// How long a read waits for the printer before reporting "nothing yet". The
/// same half second the serial transport allows with `VTIME=5`, so the printer
/// client's reply loop behaves the same on both bearers.
const read_wait_ms: i32 = 500;

/// The print channel of a BLE Niimbot printer, reached through BlueZ rather
/// than through an RFCOMM socket. A BLE-only model such as the D110 has no
/// Classic radio at all: it refuses RFCOMM with `EHOSTDOWN`, and the same
/// `55 55 … aa aa` frames travel as GATT writes here instead. Answers come back
/// as notifications, which BlueZ announces as `PropertiesChanged` signals, one
/// per notification, and also caches in the characteristic's `Value` property.
pub const Handler = struct {
    allocator: std.mem.Allocator,
    conn: *dbus.Conn,
    char_path: []u8,
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,
    /// The last value handed over, by a signal or by a read of the cache. The
    /// cache keeps a frame after it has been handed over, so a read of it can
    /// return the answer to the *last* request. Only a cached value that
    /// differs from this is new bytes.
    last: [512]u8 = undefined,
    last_len: usize = 0,

    fn close(ptr: *anyopaque) void {
        const self: *Handler = @ptrCast(@alignCast(ptr));
        self.conn.stopNotify(self.char_path);
        self.conn.deinit();
        self.buffer.deinit(self.allocator);
        self.allocator.free(self.char_path);
        self.allocator.destroy(self);
    }

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *Handler = @ptrCast(@alignCast(ptr));
        // One wire frame is far under the 244-byte MTU this printer reports,
        // so a frame is one write.
        try self.conn.writeValue(self.char_path, data);
    }

    fn read(ptr: *anyopaque, buf: []u8) !usize {
        const self: *Handler = @ptrCast(@alignCast(ptr));
        if (try self.drain(buf)) |n| return n;
        // Wait on the bus for the printer's answer, which arrives as a signal
        // the moment BlueZ has it. Reading only the cached value could not
        // tell a second, identical answer from the first, and waited out the
        // client's timeout on every repeated status: 3 s a print.
        if (try self.conn.awaitNotification(read_wait_ms)) {
            try self.takeNotified();
            return (try self.drain(buf)) orelse 0;
        }
        // No signal in the half second: read the cache, for a stack that did
        // not announce the notification. Zero means "nothing arrived", which
        // callers retry.
        try self.pull();
        return (try self.drain(buf)) orelse 0;
    }

    /// Move the bytes the signals carried into the buffer. The cache now holds
    /// the latest of them, so it becomes `last`, and the fallback read does
    /// not hand the same answer over a second time.
    fn takeNotified(self: *Handler) !void {
        try self.buffer.appendSlice(self.allocator, self.conn.notified.items);
        self.conn.notified.clearRetainingCapacity();
        const latest = self.conn.latest[0..self.conn.latest_len];
        @memcpy(self.last[0..latest.len], latest);
        self.last_len = latest.len;
    }

    /// Hand over what is already buffered, if anything.
    fn drain(self: *Handler, buf: []u8) !?usize {
        const pending = self.buffer.items.len - self.start;
        if (pending == 0) return null;
        const n = @min(buf.len, pending);
        @memcpy(buf[0..n], self.buffer.items[self.start..][0..n]);
        self.start += n;
        if (self.start == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.start = 0;
        }
        return n;
    }

    /// Ask BlueZ for the characteristic value and append the bytes if this is
    /// a value the transport has not handed over yet.
    fn pull(self: *Handler) !void {
        var scratch: [512]u8 = undefined;
        const n = self.conn.readValue(self.char_path, &scratch) catch return error.BusGone;
        if (n == 0) return;
        if (n == self.last_len and std.mem.eql(u8, self.last[0..n], scratch[0..n])) return;
        self.last_len = n;
        @memcpy(self.last[0..n], scratch[0..n]);
        try self.buffer.appendSlice(self.allocator, scratch[0..n]);
    }

    fn transport(self: *Handler) printer.Transport {
        return .{
            .ptr = self,
            .vtable = &.{ .write = Handler.write, .read = Handler.read, .close = Handler.close },
        };
    }
};

/// Connect to a BLE printer and return the transport that prints to it.
pub fn open(allocator: std.mem.Allocator, io: std.Io, address: []const u8) !printer.Transport {
    const conn = try dbus.Conn.connect(allocator, io);
    errdefer conn.deinit();

    var path_buf: [64]u8 = undefined;
    const device_path = try devicePath(&path_buf, address);
    try conn.connectDevice(device_path);
    errdefer conn.disconnectDevice(device_path);

    const char_path = (try conn.findCharacteristic(dbus.niimbot_le_characteristic)) orelse
        return error.PrintCharacteristicMissing;
    errdefer allocator.free(char_path);
    try conn.watchValue(char_path);
    try conn.startNotify(char_path);

    const self = try allocator.create(Handler);
    self.* = .{
        .allocator = allocator,
        .conn = conn,
        .char_path = char_path,
    };
    return self.transport();
}

/// The BlueZ object path for a device: `/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF`.
/// The adapter is fixed to `hci0`, which is the one the finder uses.
fn devicePath(out: []u8, address: []const u8) ![]const u8 {
    var upper: [32]u8 = undefined;
    if (address.len > upper.len) return error.BadMac;
    for (address, 0..) |c, i| upper[i] = if (c == ':') '_' else std.ascii.toUpper(c);
    return std.fmt.bufPrint(out, "/org/bluez/hci0/dev_{s}", .{upper[0..address.len]}) catch return error.BadMac;
}

test "a mac becomes the bluez device path" {
    var buf: [64]u8 = undefined;
    const path = try devicePath(&buf, "C4:17:82:12:34:56");
    try std.testing.expectEqualStrings("/org/bluez/hci0/dev_C4_17_82_12_34_56", path);
}
