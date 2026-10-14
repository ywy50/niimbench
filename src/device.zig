const std = @import("std");
const builtin = @import("builtin");
const ble = @import("ble.zig");
const corebluetooth = @import("corebluetooth.zig");
const dbus = @import("dbus.zig");
const discovery = @import("discovery.zig");
const packet = @import("packet.zig");
const printer = @import("printer.zig");

const TCGETS: u32 = 0x5401;
const TCSETS: u32 = 0x5402;
const NCCS = 19;
const Termios = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [NCCS]u8,
};

const B115200: u32 = 0o010002;
const CS8: u32 = 0o000060;
const CSIZE: u32 = 0o000060;
const CLOCAL: u32 = 0o004000;
const CREAD: u32 = 0o000200;
const PARENB: u32 = 0o000400;
const CSTOPB: u32 = 0o000100;
const CBAUD: u32 = 0o010017;
const IGNBRK: u32 = 0o000001;
const BRKINT: u32 = 0o000002;
const PARMRK: u32 = 0o000010;
const ISTRIP: u32 = 0o000040;
const INLCR: u32 = 0o000100;
const IGNCR: u32 = 0o000200;
const ICRNL: u32 = 0o000400;
const IXON: u32 = 0o002000;
const OPOST: u32 = 0o000001;
const ECHO: u32 = 0o000010;
const ECHONL: u32 = 0o000100;
const ICANON: u32 = 0o000002;
const ISIG: u32 = 0o000001;
const IEXTEN: u32 = 0o100000;
const VMIN = 6;
const VTIME = 5;

pub const Opener = *const fn (allocator: std.mem.Allocator, io: std.Io, addr: []const u8) anyerror!printer.Transport;

pub const Registry = struct {
    usb: ?Opener = null,
    bluetooth: ?Opener = null,

    pub fn open(self: Registry, conn: []const u8, allocator: std.mem.Allocator, io: std.Io, addr: []const u8) !printer.Transport {
        if (std.mem.eql(u8, conn, "usb")) {
            const open_usb = self.usb orelse return error.UsbUnavailable;
            return open_usb(allocator, io, addr);
        }
        if (std.mem.eql(u8, conn, "bluetooth")) {
            const open_bt = self.bluetooth orelse return error.BluetoothUnavailable;
            return open_bt(allocator, io, addr);
        }
        return error.UnknownConnection;
    }
};

const FdTransport = struct {
    fd: std.posix.fd_t,

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *FdTransport = @ptrCast(@alignCast(ptr));
        var off: usize = 0;
        while (off < data.len) {
            const n = try transfer(std.os.linux.write(self.fd, data[off..].ptr, data.len - off));
            if (n == 0) return error.ShortWrite;
            off += n;
        }
    }

    fn read(ptr: *anyopaque, buf: []u8) !usize {
        const self: *FdTransport = @ptrCast(@alignCast(ptr));
        return transfer(std.os.linux.read(self.fd, buf.ptr, buf.len));
    }

    fn close(ptr: *anyopaque) void {
        const self: *FdTransport = @ptrCast(@alignCast(ptr));
        _ = std.os.linux.close(self.fd);
        std.heap.page_allocator.destroy(self);
    }
};

fn fdTransport(fd: std.posix.fd_t) !printer.Transport {
    const state = try std.heap.page_allocator.create(FdTransport);
    state.* = .{ .fd = fd };
    return .{
        .ptr = state,
        .vtable = &.{ .write = FdTransport.write, .read = FdTransport.read, .close = FdTransport.close },
    };
}

pub fn openSerial(_: std.mem.Allocator, _: std.Io, addr: []const u8) !printer.Transport {
    return openSerialWithTimeout(addr, 5);
}

/// The probe opener: a tenth of a second of silence instead of half a second,
/// so asking a port that is not a printer costs a fraction of a second.
pub fn openSerialProbe(addr: []const u8) !printer.Transport {
    return openSerialWithTimeout(addr, 1);
}

fn openSerialWithTimeout(addr: []const u8, vtime: u8) !printer.Transport {
    if (addr.len == 0 or std.mem.eql(u8, addr, "auto")) return error.AddressRequired;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, addr, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    errdefer _ = std.os.linux.close(fd);
    try configureSerial(fd, vtime);
    return fdTransport(fd);
}

fn configureSerial(fd: std.posix.fd_t, vtime: u8) !void {
    var tio: Termios = undefined;
    try ioctl(fd, TCGETS, @intFromPtr(&tio));
    tio.iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    tio.oflag &= ~OPOST;
    tio.lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    tio.cflag &= ~(CSIZE | PARENB | CSTOPB | CBAUD);
    tio.cflag |= CS8 | CLOCAL | CREAD | B115200;
    tio.cc[VMIN] = 0;
    tio.cc[VTIME] = vtime;
    try ioctl(fd, TCSETS, @intFromPtr(&tio));
}

fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) !void {
    const rc = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, fd))), request, arg);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.Termios;
}

pub fn openBluetooth(allocator: std.mem.Allocator, io: std.Io, addr: []const u8) !printer.Transport {
    // macOS names a peripheral by a UUID of its own, not a MAC.
    if (builtin.os.tag == .macos) return corebluetooth.open(allocator, io, addr);
    // A BLE-only model, such as the D110, has no RFCOMM channel to reach: its
    // frames travel as GATT writes on the Niimbot vendor service. That is the
    // bearer the finder reports and the one opened here.
    if (parseMac(addr)) |_| {} else |_| return error.BadMac;
    return ble.open(allocator, io, addr);
}

fn parseMac(addr: []const u8) ![6]u8 {
    var out: [6]u8 = undefined;
    var part: usize = 0;
    var i: usize = 0;
    while (part < 6) : (part += 1) {
        if (i + 2 > addr.len) return error.BadMac;
        out[5 - part] = std.fmt.parseInt(u8, addr[i .. i + 2], 16) catch return error.BadMac;
        i += 2;
        if (part < 5) {
            if (i >= addr.len or addr[i] != ':') return error.BadMac;
            i += 1;
        }
    }
    if (i != addr.len) return error.BadMac;
    return out;
}

fn transfer(rc: usize) !usize {
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        const err: std.os.linux.E = @fromBackingInt(@intCast(-signed));
        return errnoError(err);
    }
    return @intCast(signed);
}

/// The socket calls are raw syscalls, so the errors come back as of one of
/// these, not as `std.posix` errors. `std.posix.unexpectedErrno` would panic on
/// any errno without a `std.posix` error there, and a printer that is off
/// answers RFCOMM connect with `EHOSTDOWN`, which has none. Every errno becomes
/// a named error instead, so a failed print is a message and not a crash.
fn errnoError(err: std.os.linux.E) anyerror {
    return switch (err) {
        .HOSTDOWN => error.HostDown,
        .HOSTUNREACH => error.HostUnreachable,
        .NETDOWN => error.NetworkDown,
        .NETUNREACH => error.NetworkUnreachable,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NODEV => error.NoDevice,
        else => error.SystemCallFailed,
    };
}

test "a failed syscall is an error, and an errno without a name is too" {
    const ehostdown: usize = @bitCast(@as(isize, -@as(isize, @backingInt(std.os.linux.E.HOSTDOWN))));
    try std.testing.expectError(error.HostDown, transfer(ehostdown));
    // A success passes the value through, and every errno the enum knows
    // answers with an error instead of panicking.
    try std.testing.expectEqual(@as(usize, 7), try transfer(7));
    const info = @typeInfo(std.os.linux.E).@"enum";
    inline for (info.field_values) |value| {
        if (value == 0) continue;
        const rc: usize = @bitCast(-@as(isize, @intCast(value)));
        try std.testing.expectError(errnoError(@fromBackingInt(@intCast(value))), transfer(rc));
    }
}

test "bluetooth addresses are stored reversed, like BlueZ str2ba" {
    const mac = try parseMac("AA:BB:CC:DD:EE:FF");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA }, &mac);
}

// ---- discovery ------------------------------------------------------------

/// How long an active Bluetooth inquiry runs before the device list is read.
pub const inquiry_ms = 2000;

/// Ask a printer for its model id: `PrinterInfo` (0x40) with key `0x08`, which
/// answers as `0x48`. Null means nothing that speaks the protocol is there.
/// This is the only writer a scan puts on a wire, and it only reads.
pub fn readModelId(transport: printer.Transport) !?u16 {
    const request = packet.Request.get_info;
    var wire: [packet.Packet.max_wire]u8 = undefined;
    const bytes = try (packet.Packet{ .packet_type = @backingInt(request), .data = &.{0x08} }).toBytes(&wire);
    try transport.write(bytes);
    const expect = @backingInt(request) + 8;

    var acc: [256]u8 = undefined;
    var acc_len: usize = 0;
    var tries: usize = 0;
    while (tries < 6) : (tries += 1) {
        const n = transport.read(acc[acc_len..]) catch return null;
        if (n == 0) continue;
        acc_len += n;
        var off: usize = 0;
        while (acc_len - off >= 7) {
            const frame_len = @as(usize, acc[off + 3]) + 7;
            if (acc_len - off < frame_len) break;
            var data: [packet.Packet.max_data]u8 = undefined;
            const frame = packet.Packet.fromBytes(acc[off..][0..frame_len], &data) catch {
                off += 1;
                continue;
            };
            if (frame.packet_type == expect) {
                var id: u16 = 0;
                for (frame.data) |byte| id = (id << 8) | byte;
                return id;
            }
            off += frame_len;
        }
        if (off > 0) {
            std.mem.copyForwards(u8, acc[0 .. acc_len - off], acc[off..acc_len]);
            acc_len -= off;
        }
    }
    return null;
}

/// Ports a Niimbot printer can be behind. A scan asks each one, and only a port
/// that answers the protocol is reported, so another serial device is not
/// mistaken for a printer.
pub fn findSerial(io: std.Io, allocator: std.mem.Allocator, _: bool, out: *discovery.Found) !void {
    _ = allocator;
    var names: [discovery.max_devices][24]u8 = undefined;
    var lengths: [discovery.max_devices]usize = undefined;
    var count: usize = 0;
    var dir = try std.Io.Dir.openDirAbsolute(io, "/dev", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "ttyACM") and !std.mem.startsWith(u8, entry.name, "ttyUSB")) continue;
        if (count == discovery.max_devices) break;
        if (entry.name.len > names[count].len) continue;
        @memcpy(names[count][0..entry.name.len], entry.name);
        lengths[count] = entry.name.len;
        count += 1;
    }
    for (names[0..count], lengths[0..count]) |*name_buf, name_len| {
        const name = name_buf[0..name_len];
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/dev/{s}", .{name}) catch continue;
        if (out.has(.usb, path)) continue;
        const transport = openSerialProbe(path) catch continue;
        const answer = readModelId(transport) catch null;
        transport.close();
        const model_id = answer orelse continue;
        var label_buf: [discovery.max_name]u8 = undefined;
        const label = serialLabel(io, name, &label_buf) orelse "Niimbot printer";
        out.add(.usb, path, label, discovery.modelForId(model_id), model_id, false) catch {};
    }
}

/// The USB product string for a tty, which on most Niimbot printers names the
/// model. The attribute sits on the USB device, one or two levels above the
/// tty, and the two tty classes differ, so both depths are tried.
fn serialLabel(io: std.Io, tty_name: []const u8, out: []u8) ?[]const u8 {
    const suffixes = [_][]const u8{ "device/product", "device/../product", "device/../../product" };
    for (suffixes) |suffix| {
        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/class/tty/{s}/{s}", .{ tty_name, suffix }) catch continue;
        if (readTrimmed(io, path, out)) |text| return text;
    }
    return null;
}

fn readTrimmed(io: std.Io, path: []const u8, out: []u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const len = reader.interface.readSliceShort(out) catch return null;
    const text = std.mem.trim(u8, out[0..len], " \t\r\n");
    return if (text.len == 0) null else text;
}

const BluetoothScan = struct {
    out: *discovery.Found,
    adapter_buf: [96]u8 = undefined,
    adapter_len: usize = 0,

    fn adapterPath(self: *BluetoothScan) []const u8 {
        return self.adapter_buf[0..self.adapter_len];
    }

    /// Keep devices that name themselves as Niimbot printers.
    fn put(context: *anyopaque, device: dbus.DeviceView) void {
        const self: *BluetoothScan = @ptrCast(@alignCast(context));
        const name = if (device.alias.len > 0) device.alias else device.name;
        self.out.addNamed(device.address, name, .{ .spp = device.spp, .le = device.le });
    }

    fn adapter(context: *anyopaque, path: []const u8) void {
        const self: *BluetoothScan = @ptrCast(@alignCast(context));
        if (self.adapter_len != 0 or path.len > self.adapter_buf.len) return;
        @memcpy(self.adapter_buf[0..path.len], path);
        self.adapter_len = path.len;
    }
};

/// What BlueZ knows, filtered to Niimbot printers. With `discover` the adapter
/// runs an inquiry first, so a printer that is on but never paired with this
/// machine is still seen; the passive answer is exactly the paired set.
pub fn findBluetooth(io: std.Io, allocator: std.mem.Allocator, discover: bool, out: *discovery.Found) !void {
    if (builtin.os.tag == .macos) return corebluetooth.find(io, allocator, discover, inquiry_ms, out);
    const conn = try dbus.Conn.connect(allocator, io);
    defer conn.deinit();
    var scan = BluetoothScan{ .out = out };
    const visitor = dbus.Visitor{
        .context = &scan,
        .put = BluetoothScan.put,
        .adapter = BluetoothScan.adapter,
    };
    try conn.managedObjects(visitor);
    if (!discover or scan.adapter_len == 0) return;
    conn.startDiscovery(scan.adapterPath()) catch return;
    io.sleep(.fromMilliseconds(inquiry_ms), .awake) catch {};
    conn.stopDiscovery(scan.adapterPath()) catch {};
    try conn.managedObjects(visitor);
}

const ProbeScript = struct {
    allocator: std.mem.Allocator,
    written: std.ArrayList(u8) = .empty,
    inbound: [64]u8 = undefined,
    inbound_len: usize = 0,
    pos: usize = 0,
    /// Bytes per read; 0 hands the whole answer over at once.
    chunk: usize = 0,

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *ProbeScript = @ptrCast(@alignCast(ptr));
        try self.written.appendSlice(self.allocator, data);
    }

    fn read(ptr: *anyopaque, buf: []u8) !usize {
        const self: *ProbeScript = @ptrCast(@alignCast(ptr));
        if (self.pos >= self.inbound_len) return 0;
        var available = self.inbound_len - self.pos;
        if (self.chunk != 0) available = @min(available, self.chunk);
        const n = @min(buf.len, available);
        @memcpy(buf[0..n], self.inbound[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn close(_: *anyopaque) void {}

    fn transport(self: *ProbeScript) printer.Transport {
        return .{
            .ptr = self,
            .vtable = &.{ .write = ProbeScript.write, .read = ProbeScript.read, .close = ProbeScript.close },
        };
    }

    fn answer(self: *ProbeScript, packet_type: u8, data: []const u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{ .packet_type = packet_type, .data = data }).toBytes(&wire);
        @memcpy(self.inbound[self.inbound_len..][0..bytes.len], bytes);
        self.inbound_len += bytes.len;
    }
};

test "a model id is read from the answer" {
    const gpa = std.testing.allocator;
    var script = ProbeScript{ .allocator = gpa, .chunk = 2 };
    defer script.written.deinit(gpa);
    // 768 is B21; the answer carries the id as two big-endian bytes, and the
    // reader has to stitch the frame back together from two-byte reads.
    try script.answer(0x48, &.{ 0x03, 0x00 });

    const id = try readModelId(script.transport());
    try std.testing.expectEqual(@as(?u16, 768), id);
    // The request is PrinterInfo (0x40) with key 0x08 and nothing else.
    try std.testing.expectEqual(@as(usize, 8), script.written.items.len);
    try std.testing.expectEqual(@as(u8, @backingInt(packet.Request.get_info)), script.written.items[2]);
    try std.testing.expectEqual(@as(u8, 0x08), script.written.items[4]);
}

test "a port that stays silent reports no model" {
    const gpa = std.testing.allocator;
    var script = ProbeScript{ .allocator = gpa };
    defer script.written.deinit(gpa);
    try std.testing.expect((try readModelId(script.transport())) == null);
}

fn putBluetooth(scan: *BluetoothScan, name: []const u8, address: []const u8, spp: bool) void {
    BluetoothScan.put(scan, .{
        .path = "/org/bluez/hci0/dev",
        .address = address,
        .name = name,
        .alias = name,
        .spp = spp,
    });
}

test "Bluetooth names are filtered and carry their model" {
    var found = discovery.Found{};
    var scan = BluetoothScan{ .out = &found };
    // A paired speaker advertises the serial profile too, so the name is what
    // separates it from a printer.
    putBluetooth(&scan, "Speaker", "00:00:5E:00:53:02", true);
    try std.testing.expectEqual(@as(usize, 0), found.slice().len);

    putBluetooth(&scan, "NIIMBOT B21", "AA:BB:CC:DD:EE:FF", true);
    try std.testing.expectEqual(@as(usize, 1), found.slice().len);
    try std.testing.expectEqual(discovery.modelForName("NIIMBOT B21").?, found.items[0].model.?);
    try std.testing.expect(found.items[0].spp);
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", found.items[0].addr());

    // The same address twice is one device.
    putBluetooth(&scan, "NIIMBOT B21", "AA:BB:CC:DD:EE:FF", false);
    try std.testing.expectEqual(@as(usize, 1), found.slice().len);
}
