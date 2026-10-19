const std = @import("std");
const dbus = @import("dbus.zig");
const printer = @import("printer.zig");

/// How long a read waits for the printer before reporting "nothing yet". The
/// same half second the serial transport allows with `VTIME=5`, so the printer
/// client's reply loop behaves the same on both bearers.
const read_wait_ms: i32 = 500;

/// How often a read looks for the printer's answer within that half second.
/// It answers in a few milliseconds; a read that slept the whole half second
/// before its one look made each command cost 500 ms, 2.6 s for a print's five.
const read_poll_ms: i32 = 20;

/// The print channel of a BLE Niimbot printer, reached through BlueZ rather
/// than through an RFCOMM socket. A BLE-only model such as the D110 has no
/// Classic radio at all: it refuses RFCOMM with `EHOSTDOWN`, and the same
/// `55 55 … aa aa` frames travel as GATT writes here instead. Reads come back
/// as notifications, which BlueZ caches in the characteristic's `Value`
/// property, so a read is a poll of that property plus the bytes already
/// buffered from the last one.
pub const Handler = struct {
    allocator: std.mem.Allocator,
    conn: *dbus.Conn,
    char_path: []u8,
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,
    /// The last value the stack handed over. The characteristic keeps the
    /// previous frame after it has been read, and the stack updates it
    /// asynchronously, so a poll right after a write can still return the
    /// answer to the *last* request. Only a value that differs from this is
    /// new bytes.
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
        // Nothing buffered: ask for the characteristic value, which is where
        // the stack caches what the printer notified. The property update is
        // not always announced on the bus, so polling it is what makes the
        // reply reliable. A value equal to the last one is the previous answer,
        // which `pull` skips, so polling early cannot hand it over twice. Zero
        // means "nothing arrived", which callers retry.
        var waited: i32 = 0;
        while (waited < read_wait_ms) : (waited += read_poll_ms) {
            std.Io.sleep(self.conn.io, .fromMilliseconds(read_poll_ms), .awake) catch {};
            try self.pull();
            if (try self.drain(buf)) |n| return n;
        }
        return 0;
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
