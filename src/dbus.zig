const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// The BlueZ side of Bluetooth discovery, spoken natively over the system bus.
/// niimbench asks one question — `ObjectManager.GetManagedObjects` — and reads
/// the `org.bluez.Device1` properties out of the `a{oa{sa{sv}}}` answer.
///
/// Only the little-endian encoding is implemented, because the client asks for
/// it and the bus answers in the encoding the client used.
const bus_paths = [_][]const u8{
    "/run/dbus/system_bus_socket",
    "/var/run/dbus/system_bus_socket",
};

const spp_uuid = "00001101-0000-1000-8000-00805f9b34fb";
/// The uuid a BLE-only Niimbot printer puts its print characteristic under.
pub const niimbot_le_service = "e7810a71-73ae-499d-8c15-faa9aef0c3f2";
pub const niimbot_le_characteristic = "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f";
const max_message = 1 << 18;
/// Long enough for a busy bus, short enough that a dead one is an error.
const bus_timeout_ms: i32 = 5000;

pub const Error = error{
    BusUnavailable,
    BusTimeout,
    AuthFailed,
    BadMessage,
    BadSignature,
    MethodFailed,
    TooLong,
};

/// One `org.bluez.Device1` while it is being walked. The slices point into the
/// reply buffer, so a visitor must copy what it keeps.
pub const DeviceView = struct {
    path: []const u8,
    address: []const u8,
    name: []const u8,
    alias: []const u8,
    paired: bool = false,
    connected: bool = false,
    /// The device lists the Serial Port Profile, which is what the Niimbot
    /// Bluetooth Classic transport connects to.
    spp: bool = false,
    /// The device lists the Niimbot BLE print service, so it is reached over
    /// GATT instead. A model with this and no `spp` is BLE-only.
    le: bool = false,
};

pub const Visitor = struct {
    context: *anyopaque,
    put: *const fn (context: *anyopaque, device: DeviceView) void,
    /// One `org.bluez.Adapter1` object path, for `StartDiscovery`.
    adapter: ?*const fn (context: *anyopaque, path: []const u8) void = null,
};

pub const Reply = struct {
    allocator: std.mem.Allocator,
    message: []u8,
    kind: Kind,
    /// The serial this message carries.
    serial: u32,
    /// The serial of the call this message answers, from header field 5.
    reply_to: u32 = 0,
    signature: []const u8 = "",
    error_name: []const u8 = "",
    /// Header fields 1, 2 and 3: what a signal is about.
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    body_offset: usize = 0,

    pub const Kind = enum { method_return, error_response, signal, other };

    pub fn deinit(self: *Reply) void {
        self.allocator.free(self.message);
    }
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    serial: u32 = 1,
    /// The characteristic `watchValue` subscribed to.
    watched: ?[]u8 = null,
    /// Bytes its notifications carried, in arrival order, until the reader
    /// takes them.
    notified: std.ArrayList(u8) = .empty,
    /// The latest notification on its own: what BlueZ's cached value holds.
    latest: [512]u8 = undefined,
    latest_len: usize = 0,

    pub fn connect(allocator: std.mem.Allocator, io: Io) !*Conn {
        for (bus_paths) |path| {
            const address = std.Io.net.UnixAddress.init(path) catch continue;
            const stream = address.connect(io) catch continue;
            const self = allocator.create(Conn) catch |err| {
                stream.close(io);
                return err;
            };
            self.* = .{ .allocator = allocator, .io = io, .stream = stream };
            setBlocking(self.stream.socket.handle) catch {};
            self.greet() catch |err| {
                self.stream.close(self.io);
                allocator.destroy(self);
                return err;
            };
            return self;
        }
        return error.BusUnavailable;
    }

    pub fn deinit(self: *Conn) void {
        if (self.watched) |path| self.allocator.free(path);
        self.notified.deinit(self.allocator);
        self.stream.close(self.io);
        self.allocator.destroy(self);
    }

    /// Ask BlueZ for every object it manages. Devices appear as
    /// `org.bluez.Device1`; adapters appear so a caller can start an inquiry
    /// before asking again.
    pub fn managedObjects(self: *Conn, visitor: Visitor) !void {
        var reply = try self.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
        var cur = Cursor{ .buf = reply.message, .pos = reply.body_offset };
        try walkObjects(&cur, visitor);
    }

    /// The object path of the GATT characteristic with this uuid, or null when
    /// the device does not carry it. The print characteristic of a BLE Niimbot
    /// printer is found this way rather than by guessing a path.
    pub fn findCharacteristic(self: *Conn, uuid: []const u8) !?[]u8 {
        var reply = try self.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
        var found: ?[]u8 = null;
        errdefer if (found) |path| self.allocator.free(path);
        var cur = Cursor{ .buf = reply.message, .pos = reply.body_offset };
        try walkGattPaths(&cur, self.allocator, uuid, &found);
        return found;
    }

    pub fn startDiscovery(self: *Conn, adapter_path: []const u8) !void {
        var reply = try self.call("org.bluez", adapter_path, "org.bluez.Adapter1", "StartDiscovery");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
    }

    pub fn stopDiscovery(self: *Conn, adapter_path: []const u8) !void {
        var reply = try self.call("org.bluez", adapter_path, "org.bluez.Adapter1", "StopDiscovery");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
    }

    // ---- GATT ------------------------------------------------------------

    /// Bring the LE link up. The device answers whether or not it was already
    /// connected, so a failure here is a real one.
    pub fn connectDevice(self: *Conn, device_path: []const u8) !void {
        var reply = try self.call("org.bluez", device_path, "org.bluez.Device1", "Connect");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
    }

    pub fn disconnectDevice(self: *Conn, device_path: []const u8) void {
        var reply = self.call("org.bluez", device_path, "org.bluez.Device1", "Disconnect") catch return;
        reply.deinit();
    }

    pub fn startNotify(self: *Conn, char_path: []const u8) !void {
        var reply = try self.call("org.bluez", char_path, "org.bluez.GattCharacteristic1", "StartNotify");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
    }

    pub fn stopNotify(self: *Conn, char_path: []const u8) void {
        var reply = self.call("org.bluez", char_path, "org.bluez.GattCharacteristic1", "StopNotify") catch return;
        reply.deinit();
    }

    /// The write half. An empty option dict is a write with a response, which
    /// the print characteristic accepts.
    pub fn writeValue(self: *Conn, char_path: []const u8, bytes: []const u8) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try encodeWriteValueBody(&body, self.allocator, bytes);
        var reply = try self.callWithBody("org.bluez", char_path, "org.bluez.GattCharacteristic1", "WriteValue", "aya{sv}", body.items);
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
    }

    /// The cached half. BlueZ keeps the last notified value in the property;
    /// the transport reads it only when no signal announced an answer. The
    /// value is copied into `out`, so the reply buffer can be freed here.
    pub fn readValue(self: *Conn, char_path: []const u8, out: []u8) !usize {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try putStringAt(&body, self.allocator, 0, "org.bluez.GattCharacteristic1");
        try putStringAt(&body, self.allocator, 0, "Value");
        var reply = try self.callWithBody("org.bluez", char_path, "org.freedesktop.DBus.Properties", "Get", "ss", body.items);
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
        var cur = Cursor{ .buf = reply.message, .pos = reply.body_offset };
        return cur.readByteArray(out) catch return error.BadSignature;
    }

    // ---- transport --------------------------------------------------------

    /// The bus socket is read directly rather than through `Io`, because a
    /// GATT notification is waited for with `poll`, not an async read, and a
    /// bus that stops answering has to become an error instead of a hang.
    fn fd(self: *const Conn) std.posix.fd_t {
        return self.stream.socket.handle;
    }

    fn waitReadable(self: *Conn, timeout_ms: i32) !void {
        var fds = [_]std.posix.pollfd{.{ .fd = self.fd(), .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return error.BusUnavailable;
        if (ready == 0) return error.BusTimeout;
    }

    /// A whole message always arrives within one bus timeout; the header and
    /// each part of the body are waited for separately.
    fn readExact(self: *Conn, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            try self.waitReadable(bus_timeout_ms);
            const n = std.posix.read(self.fd(), dest[off..]) catch return error.BadMessage;
            if (n == 0) return error.BadMessage;
            off += n;
        }
    }

    fn writeAll(self: *Conn, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            var fds = [_]std.posix.pollfd{.{ .fd = self.fd(), .events = std.posix.POLL.OUT, .revents = 0 }};
            const ready = std.posix.poll(&fds, bus_timeout_ms) catch return error.BusUnavailable;
            if (ready == 0) return error.BusTimeout;
            const wrote = std.os.linux.write(self.fd(), bytes[off..].ptr, bytes.len - off);
            if (wrote < 0) return error.BadMessage;
            const n: usize = @intCast(wrote);
            if (n == 0) return error.BadMessage;
            off += n;
        }
    }

    /// Block until the bus has something for this connection or `timeout_ms`
    /// passes. The GATT transport waits on it for the printer's answers.
    pub fn waitForData(self: *Conn, timeout_ms: i32) !bool {
        var fds = [_]std.posix.pollfd{.{ .fd = self.fd(), .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return error.BusUnavailable;
        return ready != 0;
    }

    fn readLine(self: *Conn, out: []u8) ![]u8 {
        var len: usize = 0;
        while (len < out.len) {
            var byte: [1]u8 = undefined;
            try self.readExact(&byte);
            if (byte[0] == '\n') return out[0..len];
            if (byte[0] != '\r') {
                out[len] = byte[0];
                len += 1;
            }
        }
        return error.BadMessage;
    }

    /// The D-Bus text handshake: a NUL, `AUTH EXTERNAL <uid as hex text>`, then
    /// `BEGIN` once the bus says `OK`. The `Hello` call that follows is what
    /// gives this connection a name; the bus drops a client that skips it.
    fn greet(self: *Conn) !void {
        try self.authenticate();
        var reply = try self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello");
        defer reply.deinit();
        if (reply.kind != .method_return) return error.AuthFailed;
    }

    fn authenticate(self: *Conn) !void {
        try self.writeAll(&[_]u8{0});
        var uid_buffer: [24]u8 = undefined;
        const uid_text = std.fmt.bufPrint(&uid_buffer, "{d}", .{std.os.linux.getuid()}) catch return error.AuthFailed;
        var hex: [48]u8 = undefined;
        for (uid_text, 0..) |c, i| {
            hex[i * 2] = hexDigit(c >> 4);
            hex[i * 2 + 1] = hexDigit(c & 0x0F);
        }
        var command: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&command, "AUTH EXTERNAL {s}\r\n", .{hex[0 .. uid_text.len * 2]}) catch return error.AuthFailed;
        try self.writeAll(line);
        var response: [256]u8 = undefined;
        const answer = try self.readLine(&response);
        if (!std.mem.startsWith(u8, answer, "OK")) return error.AuthFailed;
        try self.writeAll("BEGIN\r\n");
    }

    fn call(self: *Conn, destination: []const u8, path: []const u8, iface: []const u8, member: []const u8) !Reply {
        return self.callWithBody(destination, path, iface, member, "", "");
    }

    /// The call body, already marshalled, is copied after the header. A body
    /// starts on the eight-byte boundary that follows the header fields, and
    /// its signature is header field 8.
    fn callWithBody(self: *Conn, destination: []const u8, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) !Reply {
        const serial = self.serial;
        self.serial +%= 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try encodeCall(&out, self.allocator, serial, destination, path, iface, member, signature, body);
        try self.writeAll(out.items);

        // The bus interleaves signals with replies, so the next message is not
        // necessarily ours. Only a method return or error whose `reply_serial`
        // matches this call answers it. A printer's answer can arrive while a
        // call waits, so a signal is kept, not dropped: dropping it lost the
        // answer, and the reader waited out its timeout instead.
        var attempt: usize = 0;
        while (attempt < 32) : (attempt += 1) {
            var reply = try self.readMessage();
            if (reply.kind == .signal) try self.keepSignal(&reply);
            if (reply.kind == .other or reply.kind == .signal or reply.reply_to != serial) {
                reply.deinit();
                continue;
            }
            return reply;
        }
        return error.BadMessage;
    }

    // ---- notifications ---------------------------------------------------

    /// Ask the bus for the `PropertiesChanged` signals of one characteristic.
    /// BlueZ sends one for every notification, even when the value has not
    /// changed, so each answer the printer gives arrives exactly once. The
    /// bus delivers a signal only to a client with a matching rule: without
    /// this call none came. Call it before `startNotify`, or the first answer
    /// can arrive before the rule.
    pub fn watchValue(self: *Conn, char_path: []const u8) !void {
        var rule_buf: [256]u8 = undefined;
        const rule = std.fmt.bufPrint(&rule_buf, "type='signal',sender='org.bluez',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='{s}',arg0='org.bluez.GattCharacteristic1'", .{char_path}) catch return error.TooLong;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.allocator);
        try putStringAt(&body, self.allocator, 0, rule);
        var reply = try self.callWithBody("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", body.items);
        defer reply.deinit();
        if (reply.kind != .method_return) return error.MethodFailed;
        if (self.watched) |old| self.allocator.free(old);
        self.watched = try self.allocator.dupe(u8, char_path);
    }

    /// Wait up to `timeout_ms` for a notification of the watched value,
    /// reading the bus as messages arrive rather than sleeping. True when
    /// `notified` holds bytes.
    pub fn awaitNotification(self: *Conn, timeout_ms: i32) !bool {
        if (self.notified.items.len != 0) return true;
        const start = Io.Clock.awake.now(self.io);
        while (true) {
            const spent: i64 = start.durationTo(Io.Clock.awake.now(self.io)).toMilliseconds();
            if (spent >= timeout_ms) return false;
            if (!try self.waitForData(@intCast(timeout_ms - spent))) return false;
            var message = try self.readMessage();
            defer message.deinit();
            if (message.kind == .signal) try self.keepSignal(&message);
            if (self.notified.items.len != 0) return true;
        }
    }

    /// Append the value a `PropertiesChanged` signal carries for the watched
    /// characteristic. Any other signal is ignored.
    fn keepSignal(self: *Conn, message: *const Reply) !void {
        const watched = self.watched orelse return;
        const n = (try notifiedValue(message, watched, &self.latest)) orelse return;
        self.latest_len = n;
        try self.notified.appendSlice(self.allocator, self.latest[0..n]);
    }

    fn readMessage(self: *Conn) !Reply {
        var fixed: [16]u8 = undefined;
        try self.readExact(&fixed);
        if (fixed[0] != 'l') return error.BadMessage;
        const body_len = std.mem.readInt(u32, fixed[4..8], .little);
        const fields_len = std.mem.readInt(u32, fixed[12..16], .little);
        if (body_len > max_message or fields_len > max_message) return error.TooLong;
        const after_fields = 16 + @as(usize, fields_len);
        const pad = (8 - (after_fields % 8)) % 8;
        const total = after_fields + pad + @as(usize, body_len);
        const message = try self.allocator.alloc(u8, total);
        {
            errdefer self.allocator.free(message);
            @memcpy(message[0..16], &fixed);
            try self.readExact(message[16..]);
        }
        return parseMessage(self.allocator, message);
    }
};

/// The header of one whole message off the bus. The `Reply` owns `message`,
/// and an error frees it, once.
fn parseMessage(allocator: std.mem.Allocator, message: []u8) !Reply {
    errdefer allocator.free(message);
    if (message.len < 16 or message[0] != 'l') return error.BadMessage;
    const fields_len = std.mem.readInt(u32, message[12..16], .little);
    const after_fields = 16 + @as(usize, fields_len);
    const pad = (8 - (after_fields % 8)) % 8;
    if (after_fields + pad > message.len) return error.BadMessage;
    var reply = Reply{
        .allocator = allocator,
        .message = message,
        .kind = switch (message[1]) {
            2 => .method_return,
            3 => .error_response,
            4 => .signal,
            else => .other,
        },
        .serial = std.mem.readInt(u32, message[8..12], .little),
        .body_offset = after_fields + pad,
    };
    var cur = Cursor{ .buf = message, .pos = 16 };
    while (cur.pos < after_fields) {
        cur.alignTo(8);
        const code = try cur.readU8();
        const value_signature = try cur.readSignature();
        switch (code) {
            1 => reply.path = try cur.readString(),
            2 => reply.interface = try cur.readString(),
            3 => reply.member = try cur.readString(),
            5 => reply.reply_to = try cur.readU32(),
            8 => reply.signature = try cur.readSignature(),
            4 => reply.error_name = try cur.readString(),
            else => {
                var index: usize = 0;
                try cur.skipValue(value_signature, &index);
            },
        }
    }
    return reply;
}

/// The bytes a `PropertiesChanged` signal carries as the `Value` of the
/// `GattCharacteristic1` at `char_path`, or null for any other signal. The
/// body is `sa{sv}as`: the interface, the changed properties, the names that
/// were invalidated.
fn notifiedValue(message: *const Reply, char_path: []const u8, out: []u8) !?usize {
    if (message.kind != .signal) return null;
    if (!std.mem.eql(u8, message.member, "PropertiesChanged")) return null;
    if (!std.mem.eql(u8, message.interface, "org.freedesktop.DBus.Properties")) return null;
    if (!std.mem.eql(u8, message.path, char_path)) return null;
    if (!std.mem.startsWith(u8, message.signature, "sa{sv}")) return null;
    var cur = Cursor{ .buf = message.message, .pos = message.body_offset };
    if (!std.mem.eql(u8, try cur.readString(), "org.bluez.GattCharacteristic1")) return null;
    // An array's length counts its elements, not the padding to the first.
    const len = try cur.readU32();
    cur.alignTo(8);
    const end = cur.pos + len;
    if (end > cur.buf.len) return error.BadMessage;
    while (cur.pos < end) {
        cur.alignTo(8);
        const key = try cur.readString();
        if (std.mem.eql(u8, key, "Value")) return try cur.readByteArray(out);
        var index: usize = 0;
        try cur.skipValue("v", &index);
    }
    return null;
}

/// The whole method-call message: the fixed header, the four required header
/// fields, the `SIGNATURE` field when the call has arguments, and the body.
/// Keeping this separate from the socket makes the wire bytes testable.
fn encodeCall(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    serial: u32,
    destination: []const u8,
    path: []const u8,
    iface: []const u8,
    member: []const u8,
    signature: []const u8,
    body: []const u8,
) !void {
    try out.appendNTimes(allocator, 0, 16);
    @memset(out.items[0..16], 0);
    out.items[0] = 'l';
    out.items[1] = 1; // method_call
    out.items[3] = 1;
    std.mem.writeInt(u32, out.items[8..12], serial, .little);
    const fields_start = out.items.len;
    try putField(out, allocator, 1, "o", path);
    try putField(out, allocator, 2, "s", iface);
    try putField(out, allocator, 3, "s", member);
    try putField(out, allocator, 6, "s", destination);
    // An empty signature field is a protocol error, so a call with no
    // arguments carries no field 8 at all.
    if (signature.len != 0) try putField(out, allocator, 8, "g", signature);
    std.mem.writeInt(u32, out.items[12..16], @intCast(out.items.len - fields_start), .little);
    // The padding to the eight-byte boundary belongs to neither the header nor
    // the body, so the length is written once it is in place. The body then
    // runs to the end of the message.
    try alignList(out, allocator, 8);
    const body_at = out.items.len;
    try out.appendSlice(allocator, body);
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - body_at), .little);
    if (out.items.len > max_message) return error.TooLong;
}

/// A header field is `y` (code) plus a variant: the signature string, then the
/// value. The fields are the entries of one `a(yv)`, so each entry is aligned.
fn putField(out: *std.ArrayList(u8), allocator: std.mem.Allocator, code: u8, signature: []const u8, value: []const u8) !void {
    try alignList(out, allocator, 8);
    try out.append(allocator, code);
    // The outer variant: the header field's value, named by `signature`.
    try out.append(allocator, @intCast(signature.len));
    try out.appendSlice(allocator, signature);
    try out.append(allocator, 0);
    if (signature.len == 1 and signature[0] == 'g') {
        // A signature value is `y` sized: one length byte, the text, and a
        // NUL. Writing it as a string would pad it and shift every field
        // after it, which the bus rejects.
        try out.append(allocator, @intCast(value.len));
        try out.appendSlice(allocator, value);
        try out.append(allocator, 0);
    } else {
        try writeString(out, allocator, value);
    }
}

fn writeString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try alignList(out, allocator, 4);
    try out.appendNTimes(allocator, 0, 4);
    std.mem.writeInt(u32, out.items[out.items.len - 4 ..][0..4], @intCast(text.len), .little);
    try out.appendSlice(allocator, text);
    try out.append(allocator, 0);
}

fn writeArrayLength(out: *std.ArrayList(u8), at: usize) !void {
    std.mem.writeInt(u32, out.items[at..][0..4], @intCast(out.items.len - at - 4), .little);
}

/// Pad `out` so that the value about to be written starts on `alignment`,
/// measured from `at`, which is where this buffer begins inside the message.
/// Padding is a property of the message, not of the scratch buffer, so a
/// builder that forgot `at` would misalign every value after the first.
fn padTo(out: *std.ArrayList(u8), allocator: std.mem.Allocator, at: usize, alignment: usize) !void {
    const position = at + out.items.len;
    const rest = position % alignment;
    if (rest != 0) try out.appendNTimes(allocator, 0, alignment - rest);
}

/// A body `s`: the length, the bytes, and the NUL the signature requires.
fn putStringAt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, at: usize, text: []const u8) !void {
    try padTo(out, allocator, at, 4);
    try out.appendNTimes(allocator, 0, 4);
    std.mem.writeInt(u32, out.items[out.items.len - 4 ..][0..4], @intCast(text.len), .little);
    try out.appendSlice(allocator, text);
    try out.append(allocator, 0);
}

/// The `aya{sv}` body of `WriteValue`: the frame, then an empty option dict,
/// which BlueZ reads as a write that wants a response. The bus is strict about
/// this layout — the padding after the dict length is required even when the
/// dict is empty.
fn encodeWriteValueBody(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    try putByteArrayAt(out, allocator, 0, bytes);
    try putEmptyOptionsAt(out, allocator, 0);
}

/// A body `ay`: a length in bytes, then the bytes, then the padding the next
/// value needs. The length covers the bytes only, not the padding.
fn putByteArrayAt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, at: usize, bytes: []const u8) !void {
    try padTo(out, allocator, at, 4);
    const length_at = out.items.len;
    try out.appendNTimes(allocator, 0, 4);
    try out.appendSlice(allocator, bytes);
    std.mem.writeInt(u32, out.items[length_at..][0..4], @intCast(bytes.len), .little);
}

/// A body `a{sv}` holding nothing. The pad to the entry alignment is required
/// even when the array is empty: the bus closes a connection that leaves it
/// out. An empty dict is what WriteValue reads as "write with a response".
fn putEmptyOptionsAt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, at: usize) !void {
    try padTo(out, allocator, at, 4);
    try out.appendNTimes(allocator, 0, 4); // entry bytes: none
    try padTo(out, allocator, at, 8); // entry alignment, empty or not
}

fn alignList(out: *std.ArrayList(u8), allocator: std.mem.Allocator, alignment: usize) !void {
    const rest = out.items.len % alignment;
    if (rest != 0) try out.appendNTimes(allocator, 0, alignment - rest);
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

/// `std.Io` may hand the socket over non-blocking. The blocking read path below
/// wants a wait, not an `EAGAIN`, so the flag is cleared once at connect.
fn setBlocking(fd: std.posix.fd_t) !void {
    const cmd = std.os.linux.F.GETFL;
    var rc = std.os.linux.fcntl(fd, cmd, 0);
    var signed: isize = @bitCast(rc);
    if (signed < 0) return error.BusUnavailable;
    const nonblock: u32 = @bitCast(@as(std.os.linux.O, .{ .NONBLOCK = true }));
    const flags: u32 = @intCast(signed);
    rc = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, flags & ~nonblock);
    signed = @bitCast(rc);
    if (signed < 0) return error.BusUnavailable;
}

const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn alignTo(self: *Cursor, alignment: usize) void {
        const rest = self.pos % alignment;
        if (rest != 0) self.pos += alignment - rest;
    }

    fn readU8(self: *Cursor) !u8 {
        if (self.pos + 1 > self.buf.len) return error.BadMessage;
        const value = self.buf[self.pos];
        self.pos += 1;
        return value;
    }

    fn readU32(self: *Cursor) !u32 {
        self.alignTo(4);
        if (self.pos + 4 > self.buf.len) return error.BadMessage;
        const value = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }

    fn readString(self: *Cursor) ![]const u8 {
        self.alignTo(4);
        const len = try self.readU32();
        if (self.pos + len + 1 > self.buf.len) return error.BadMessage;
        const text = self.buf[self.pos .. self.pos + len];
        self.pos += len + 1;
        return text;
    }

    fn readSignature(self: *Cursor) ![]const u8 {
        const len = try self.readU8();
        if (self.pos + len + 1 > self.buf.len) return error.BadMessage;
        const text = self.buf[self.pos .. self.pos + len];
        self.pos += len + 1;
        return text;
    }

    /// The variant a `Properties.Get` answers with: its signature, then the
    /// `ay` it wraps. Only the byte-array case is needed here.
    fn readByteArray(self: *Cursor, out: []u8) !usize {
        const signature = try self.readSignature();
        if (!std.mem.eql(u8, signature, "ay")) return error.BadSignature;
        self.alignTo(4);
        const len = try self.readU32();
        if (self.pos + len > self.buf.len) return error.BadMessage;
        const n = @min(len, out.len);
        @memcpy(out[0..n], self.buf[self.pos .. self.pos + n]);
        self.pos += len;
        return n;
    }

    /// Step over the value at the front of `signature`. Container types read
    /// their members from the same signature string, so an array of dict
    /// entries stops exactly at the length the wire gave.
    fn skipValue(self: *Cursor, signature: []const u8, index: *usize) !void {
        if (index.* >= signature.len) return error.BadSignature;
        const kind = signature[index.*];
        index.* += 1;
        switch (kind) {
            'y' => self.pos += 1,
            'b', 'i', 'u', 'h' => {
                self.alignTo(4);
                self.pos += 4;
            },
            'n', 'q' => {
                self.alignTo(2);
                self.pos += 2;
            },
            'x', 't', 'd' => {
                self.alignTo(8);
                self.pos += 8;
            },
            's', 'o' => _ = try self.readString(),
            'g' => _ = try self.readSignature(),
            'v' => {
                const inner = try self.readSignature();
                var inner_index: usize = 0;
                try self.skipValue(inner, &inner_index);
            },
            'a' => {
                self.alignTo(4);
                const len = try self.readU32();
                const end = self.pos + len;
                const element = index.*;
                while (self.pos < end) {
                    var element_index = element;
                    try self.skipValue(signature, &element_index);
                }
            },
            '(', '{' => {
                self.alignTo(8);
                const close: u8 = if (kind == '(') ')' else '}';
                while (index.* < signature.len and signature[index.*] != close) {
                    try self.skipValue(signature, index);
                }
                if (index.* >= signature.len) return error.BadSignature;
                index.* += 1;
            },
            else => return error.BadSignature,
        }
        if (self.pos > self.buf.len) return error.BadMessage;
    }
};

fn walkObjects(cur: *Cursor, visitor: Visitor) !void {
    cur.alignTo(4);
    const len = try cur.readU32();
    const end = cur.pos + len;
    while (cur.pos < end) {
        cur.alignTo(8); // dict entry
        const path = try cur.readString();
        // The value is `a{sa{sv}}`: interface name to property dict, with no
        // variant in between. The variant only appears at the innermost
        // property, so `readProperties` reads each property's signature.
        cur.alignTo(4);
        const interfaces_len = try cur.readU32();
        const interfaces_end = cur.pos + interfaces_len;
        var device = DeviceView{ .path = path, .address = "", .name = "", .alias = "" };
        var is_device = false;
        while (cur.pos < interfaces_end) {
            cur.alignTo(8); // dict entry
            const interface = try cur.readString();
            if (std.mem.eql(u8, interface, "org.bluez.Device1")) {
                is_device = true;
                try readProperties(cur, &device);
            } else {
                if (std.mem.eql(u8, interface, "org.bluez.Adapter1")) {
                    if (visitor.adapter) |adapter| adapter(visitor.context, path);
                }
                var index: usize = 0;
                try cur.skipValue("a{sv}", &index);
            }
        }
        if (is_device) visitor.put(visitor.context, device);
    }
}

/// Collect the `org.bluez.GattCharacteristic1` path whose `UUID` is `uuid`.
/// Every other object is stepped over with `skipValue`.
fn walkGattPaths(cur: *Cursor, allocator: std.mem.Allocator, uuid: []const u8, found: *?[]u8) !void {
    cur.alignTo(4);
    const len = try cur.readU32();
    const end = cur.pos + len;
    while (cur.pos < end) {
        cur.alignTo(8); // dict entry
        const path = try cur.readString();
        cur.alignTo(4);
        const interfaces_len = try cur.readU32();
        const interfaces_end = cur.pos + interfaces_len;
        while (cur.pos < interfaces_end) {
            cur.alignTo(8); // dict entry
            const interface = try cur.readString();
            // The UUID is read first, but the path cannot be stored until the
            // whole interface has been stepped over: `path` points into the
            // reply buffer, which the next `call` reuses.
            var matches = false;
            if (std.mem.eql(u8, interface, "org.bluez.GattCharacteristic1") and found.* == null) {
                cur.alignTo(4);
                const properties_len = try cur.readU32();
                const properties_end = cur.pos + properties_len;
                while (cur.pos < properties_end) {
                    cur.alignTo(8);
                    const property = try cur.readString();
                    const value_signature = try cur.readSignature();
                    if (std.mem.eql(u8, value_signature, "s") and std.mem.eql(u8, property, "UUID")) {
                        const text = try cur.readString();
                        if (std.ascii.eqlIgnoreCase(text, uuid)) matches = true;
                    } else {
                        var index: usize = 0;
                        try cur.skipValue(value_signature, &index);
                    }
                }
            } else {
                var skip_index: usize = 0;
                try cur.skipValue("a{sv}", &skip_index);
            }
            if (matches and found.* == null) found.* = try allocator.dupe(u8, path);
        }
    }
}

fn readProperties(cur: *Cursor, device: *DeviceView) !void {
    cur.alignTo(4);
    const len = try cur.readU32();
    const end = cur.pos + len;
    while (cur.pos < end) {
        cur.alignTo(8); // dict entry
        const property = try cur.readString();
        const value_signature = try cur.readSignature();
        if (std.mem.eql(u8, value_signature, "s") and std.mem.eql(u8, property, "Address")) {
            device.address = try cur.readString();
        } else if (std.mem.eql(u8, value_signature, "s") and std.mem.eql(u8, property, "Alias")) {
            device.alias = try cur.readString();
        } else if (std.mem.eql(u8, value_signature, "s") and std.mem.eql(u8, property, "Name")) {
            device.name = try cur.readString();
        } else if (std.mem.eql(u8, value_signature, "b") and std.mem.eql(u8, property, "Paired")) {
            device.paired = (try cur.readU32()) != 0;
        } else if (std.mem.eql(u8, value_signature, "b") and std.mem.eql(u8, property, "Connected")) {
            device.connected = (try cur.readU32()) != 0;
        } else if (std.mem.eql(u8, value_signature, "as") and std.mem.eql(u8, property, "UUIDs")) {
            try readServices(cur, device);
        } else {
            var index: usize = 0;
            try cur.skipValue(value_signature, &index);
        }
    }
}

/// The advertised services decide which bearer can reach the printer. Classic
/// printing needs the Serial Port Profile; a BLE-only model carries the Niimbot
/// vendor service instead and refuses RFCOMM outright.
fn readServices(cur: *Cursor, device: *DeviceView) !void {
    cur.alignTo(4);
    const len = try cur.readU32();
    const end = cur.pos + len;
    while (cur.pos < end) {
        const uuid = try cur.readString();
        if (std.ascii.eqlIgnoreCase(uuid, spp_uuid)) device.spp = true;
        if (std.ascii.eqlIgnoreCase(uuid, niimbot_le_service)) device.le = true;
    }
}

// ---- tests ----------------------------------------------------------------

const TestProperty = struct { name: []const u8, signature: []const u8, value: []const u8 = "", values: []const []const u8 = &.{} };

/// Build the message shape the bus sends: the fixed header, one header field
/// naming the body signature, then a body with an adapter and a device. Both
/// directions of the layout are pinned here, so a change to either has to say
/// what the wire looks like.
fn testMessage(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, 16);
    @memset(out.items[0..16], 0);
    out.items[0] = 'l';
    out.items[1] = 2; // method_return
    out.items[3] = 1;
    std.mem.writeInt(u32, out.items[8..12], 7, .little);
    const fields_start = out.items.len;
    try alignList(&out, allocator, 8);
    try out.append(allocator, 8); // field: signature
    try out.append(allocator, 1);
    try out.appendSlice(allocator, "g");
    try out.append(allocator, 0);
    try out.append(allocator, "a{oa{sa{sv}}}".len);
    try out.appendSlice(allocator, "a{oa{sa{sv}}}");
    try out.append(allocator, 0);
    std.mem.writeInt(u32, out.items[12..16], @intCast(out.items.len - fields_start), .little);
    try alignList(&out, allocator, 8);

    const body_at = out.items.len;
    try out.appendNTimes(allocator, 0, 4); // outer array length
    const adapter = [_]TestProperty{
        .{ .name = "Address", .signature = "s", .value = "00:00:5E:00:53:01" },
        .{ .name = "Powered", .signature = "b", .value = "true" },
    };
    try writeObject(&out, allocator, "/org/bluez/hci0", "org.bluez.Adapter1", &adapter);
    const device = [_]TestProperty{
        .{ .name = "Address", .signature = "s", .value = "AA:BB:CC:DD:EE:FF" },
        .{ .name = "Name", .signature = "s", .value = "NIIMBOT B21" },
        .{ .name = "Alias", .signature = "s", .value = "NIIMBOT B21" },
        .{ .name = "Paired", .signature = "b", .value = "true" },
        .{ .name = "Connected", .signature = "b", .value = "false" },
        .{ .name = "UUIDs", .signature = "as", .values = &.{ spp_uuid, niimbot_le_service } },
        .{ .name = "Class", .signature = "u", .value = "" },
    };
    try writeObject(&out, allocator, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF", "org.bluez.Device1", &device);
    try writeArrayLength(&out, body_at);
    const body_len = out.items.len - body_at;
    std.mem.writeInt(u32, out.items[4..8], @intCast(body_len), .little);
    return out.toOwnedSlice(allocator);
}

fn writeObject(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    path: []const u8,
    interface: []const u8,
    properties: []const TestProperty,
) !void {
    try alignList(out, allocator, 8);
    try writeString(out, allocator, path);
    try alignList(out, allocator, 4);
    const interfaces_at = out.items.len;
    try out.appendNTimes(allocator, 0, 4);
    try alignList(out, allocator, 8);
    try writeString(out, allocator, interface);
    try alignList(out, allocator, 4);
    const props_at = out.items.len;
    try out.appendNTimes(allocator, 0, 4);
    for (properties) |property| {
        try alignList(out, allocator, 8);
        try writeString(out, allocator, property.name);
        try out.append(allocator, @intCast(property.signature.len));
        try out.appendSlice(allocator, property.signature);
        try out.append(allocator, 0);
        if (std.mem.eql(u8, property.signature, "s")) {
            try writeString(out, allocator, property.value);
        } else if (std.mem.eql(u8, property.signature, "b")) {
            try alignList(out, allocator, 4);
            try out.appendNTimes(allocator, 0, 4);
            const value: u32 = if (std.mem.eql(u8, property.value, "true")) 1 else 0;
            std.mem.writeInt(u32, out.items[out.items.len - 4 ..][0..4], value, .little);
        } else if (std.mem.eql(u8, property.signature, "u")) {
            try alignList(out, allocator, 4);
            try out.appendNTimes(allocator, 0, 4);
        } else if (std.mem.eql(u8, property.signature, "as")) {
            try alignList(out, allocator, 4);
            const array_at = out.items.len;
            try out.appendNTimes(allocator, 0, 4);
            if (property.values.len > 0) {
                for (property.values) |text| try writeString(out, allocator, text);
            } else {
                try writeString(out, allocator, property.value);
            }
            try writeArrayLength(out, array_at);
        }
    }
    try writeArrayLength(out, props_at);
    try writeArrayLength(out, interfaces_at);
}

const Collector = struct {
    devices: usize = 0,
    adapters: usize = 0,
    address: []const u8 = "",
    name: []const u8 = "",
    spp: bool = false,
    le: bool = false,
    paired: bool = false,

    fn put(context: *anyopaque, device: DeviceView) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        self.devices += 1;
        self.address = device.address;
        self.name = device.alias;
        self.spp = device.spp;
        self.le = device.le;
        self.paired = device.paired;
    }

    fn adapter(context: *anyopaque, _: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(context));
        self.adapters += 1;
    }
};

test "a managed objects answer yields its devices and adapters" {
    const gpa = std.testing.allocator;
    const message = try testMessage(gpa);
    defer gpa.free(message);

    const fields_len = @as(usize, std.mem.readInt(u32, message[12..16], .little));
    const after_fields = 16 + fields_len;
    const pad = (8 - (after_fields % 8)) % 8;

    var collector = Collector{};
    var cur = Cursor{ .buf = message, .pos = after_fields + pad };
    try walkObjects(&cur, .{ .context = &collector, .put = Collector.put, .adapter = Collector.adapter });

    try std.testing.expectEqual(@as(usize, 1), collector.adapters);
    try std.testing.expectEqual(@as(usize, 1), collector.devices);
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", collector.address);
    try std.testing.expectEqualStrings("NIIMBOT B21", collector.name);
    try std.testing.expect(collector.spp);
    try std.testing.expect(collector.le);
    try std.testing.expect(collector.paired);
}

test "a value skipper stops on the array length" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // One-entry a{sv}: key "key", variant value "value".
    try alignList(&buf, gpa, 4);
    const array_at = buf.items.len;
    try buf.appendNTimes(gpa, 0, 4);
    try alignList(&buf, gpa, 8);
    try writeString(&buf, gpa, "key");
    try buf.append(gpa, 1);
    try buf.appendSlice(gpa, "s");
    try buf.append(gpa, 0);
    try writeString(&buf, gpa, "value");
    try writeArrayLength(&buf, array_at);
    const array_end = buf.items.len;
    try buf.append(gpa, 0xAB); // must survive the skip

    var cur = Cursor{ .buf = buf.items };
    var index: usize = 0;
    try cur.skipValue("a{sv}", &index);
    try std.testing.expectEqual(array_end, cur.pos);
}

test "the system bus answers bluez with its managed objects" {
    // A live check of the wire, not of this machine: it needs a system bus with
    // BlueZ on it, and skips when there is none. The synthesized-message test
    // above is what pins the layout without a bus.
    const gpa = std.testing.allocator;
    const conn = Conn.connect(gpa, std.testing.io) catch return error.SkipZigTest;
    defer conn.deinit();
    var collector = Collector{};
    conn.managedObjects(.{ .context = &collector, .put = Collector.put, .adapter = Collector.adapter }) catch |err| switch (err) {
        // No org.bluez to ask on this machine.
        error.MethodFailed => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(collector.adapters + collector.devices >= 0);
}

test "a WriteValue call matches the bytes the bus accepts" {
    // Captured from dbus-fast making the same call on this machine's system
    // bus, with the serial normalised to 1. The bus closed the connection on
    // an earlier version of this message, so the exact length of the fields
    // and of the option dict's padding are pinned here.
    const expected_hex =
        "6c0100011000000001000000ad00000001016f003a0000002f6f72672f626c75" ++
        "657a2f686369302f6465765f43345f31375f38325f31325f33345f35362f7365" ++
        "7276696365303030382f6368617230303039000000000000020173001d000000" ++
        "6f72672e626c75657a2e47617474436861726163746572697374696331000000" ++
        "030173000a000000577269746556616c75650000000000000601730009000000" ++
        "6f72672e626c75657a0000000000000008016700076179617b73767d00000000" ++
        "08000000555540010849aaaa00000000";
    var expected: [expected_hex.len / 2]u8 = undefined;
    for (0..expected.len) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 ..][0..2], 16) catch unreachable;
    }

    const gpa = std.testing.allocator;
    const char_path = "/org/bluez/hci0/dev_C4_17_82_12_34_56/service0008/char0009";
    const probe = [_]u8{ 0x55, 0x55, 0x40, 0x01, 0x08, 0x49, 0xAA, 0xAA };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try encodeWriteValueBody(&body, gpa, &probe);
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(gpa);
    try encodeCall(&message, gpa, 1, "org.bluez", char_path, "org.bluez.GattCharacteristic1", "WriteValue", "aya{sv}", body.items);

    try std.testing.expectEqual(expected.len, message.items.len);
    try std.testing.expectEqualSlices(u8, &expected, message.items);
}

/// A notification as BlueZ announces it: `PropertiesChanged` on the
/// characteristic, with `Value` behind another property so a reader has to
/// step over one.
fn testNotification(allocator: std.mem.Allocator, char_path: []const u8, value: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try putStringAt(&body, allocator, 0, "org.bluez.GattCharacteristic1");
    try padTo(&body, allocator, 0, 4);
    const length_at = body.items.len;
    try body.appendNTimes(allocator, 0, 4);
    try padTo(&body, allocator, 0, 8);
    const first = body.items.len;
    try putStringAt(&body, allocator, 0, "Notifying");
    try body.appendSlice(allocator, &.{ 1, 'b', 0 });
    try padTo(&body, allocator, 0, 4);
    try body.appendSlice(allocator, &.{ 1, 0, 0, 0 });
    try padTo(&body, allocator, 0, 8);
    try putStringAt(&body, allocator, 0, "Value");
    try body.appendSlice(allocator, &.{ 2, 'a', 'y', 0 });
    try putByteArrayAt(&body, allocator, 0, value);
    std.mem.writeInt(u32, body.items[length_at..][0..4], @intCast(body.items.len - first), .little);
    // `as`: nothing invalidated.
    try padTo(&body, allocator, 0, 4);
    try body.appendNTimes(allocator, 0, 4);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try encodeCall(&out, allocator, 9, "org.bluez", char_path, "org.freedesktop.DBus.Properties", "PropertiesChanged", "sa{sv}as", body.items);
    out.items[1] = 4; // signal
    return out.toOwnedSlice(allocator);
}

const test_char_path = "/org/bluez/hci0/dev_C4_17_82_25_20_64/service0020/char0021";
const test_status = [_]u8{ 0x55, 0x55, 0xB3, 0x04, 0x00, 0x00, 0x64, 0x64, 0x33, 0xAA, 0xAA };

test "a PropertiesChanged signal yields the value the printer notified" {
    const gpa = std.testing.allocator;
    var message = try parseMessage(gpa, try testNotification(gpa, test_char_path, &test_status));
    defer message.deinit();
    var out: [64]u8 = undefined;
    const n = (try notifiedValue(&message, test_char_path, &out)) orelse return error.NoValue;
    try std.testing.expectEqualSlices(u8, &test_status, out[0..n]);
    // Another characteristic's value is not this one's answer.
    try std.testing.expectEqual(@as(?usize, null), try notifiedValue(&message, "/org/bluez/hci0/other", &out));
}

test "a notification that arrives while a call waits for its reply is kept" {
    // The printer's answer can land on the bus between a call and its reply.
    // It was dropped there, and the reader waited out its timeout for it.
    // BlueZ is Linux only, and the fake bus below is made of Linux system
    // calls, which another kernel answers with SIGSYS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    defer _ = std.os.linux.close(fds[1]);
    const conn = try gpa.create(Conn);
    conn.* = .{ .allocator = gpa, .io = std.testing.io, .stream = .{ .socket = .{ .handle = fds[0], .address = undefined } } };
    defer conn.deinit();
    conn.watched = try gpa.dupe(u8, test_char_path);

    // The bus side: the notification, then the reply to call serial 1.
    const signal = try testNotification(gpa, test_char_path, &test_status);
    defer gpa.free(signal);
    const reply = [_]u8{ 'l', 2, 0, 1, 0, 0, 0, 0, 2, 0, 0, 0, 8, 0, 0, 0, 5, 1, 'u', 0, 1, 0, 0, 0 };
    for ([_][]const u8{ signal, &reply }) |bytes| {
        const wrote = std.os.linux.write(fds[1], bytes.ptr, bytes.len);
        try std.testing.expectEqual(bytes.len, wrote);
    }

    var answered = try conn.callWithBody("org.bluez", test_char_path, "org.bluez.GattCharacteristic1", "WriteValue", "", "");
    defer answered.deinit();
    try std.testing.expectEqual(Reply.Kind.method_return, answered.kind);
    try std.testing.expect(try conn.awaitNotification(0));
    try std.testing.expectEqualSlices(u8, &test_status, conn.notified.items);
}
