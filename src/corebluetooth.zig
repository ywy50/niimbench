const std = @import("std");
const builtin = @import("builtin");
const dbus = @import("dbus.zig");
const discovery = @import("discovery.zig");
const printer = @import("printer.zig");

/// Bluetooth on macOS, the finder and the print channel, through Apple's
/// CoreBluetooth. macOS has no BlueZ and no Bluetooth socket a program can
/// open; a BLE link belongs to CoreBluetooth, an Objective-C framework. It is
/// reached through the Objective-C runtime at run time: `dlopen` the runtime
/// and the framework, look classes and selectors up by name, and call
/// `objc_msgSend`. Nothing links against Apple's SDK, so the macOS binary
/// builds on Linux like the others.
///
/// CoreBluetooth answers through a delegate. The delegate is a class made at
/// run time whose methods are the `on*` functions below. They run on a
/// dispatch queue of the link's own, record what happened in the `Link` under
/// its lock and signal a semaphore that the waiting call sleeps on.
///
/// macOS does not show a program a Bluetooth address. A peripheral is known by
/// a UUID this Mac made up for it, and that UUID is the address niimbench
/// reports and prints to.
const Id = ?*anyopaque;
const Sel = ?*anyopaque;

/// How long the radio may take to say whether it is on. The first time a
/// program asks, macOS asks the person whether the terminal may use
/// Bluetooth, and the answer is part of this wait.
const power_ms = 30_000;
const connect_ms = 15_000;
/// Service and characteristic discovery, and the notify switch.
const setup_ms = 10_000;
/// One frame written with a response.
const write_ms = 5_000;
/// The same half second the serial and BlueZ transports wait for an answer.
const read_wait_ms = 500;

const CBManagerState = enum(isize) { unknown = 0, resetting = 1, unsupported = 2, unauthorized = 3, powered_off = 4, powered_on = 5, _ };
const write_with_response: isize = 0;

extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_signal(semaphore: ?*anyopaque) isize;
extern "c" fn dispatch_semaphore_wait(semaphore: ?*anyopaque, timeout: u64) isize;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_sync_f(queue: ?*anyopaque, context: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_release(object: ?*anyopaque) void;

/// The runtime functions, looked up once. Not a registry: the process has one
/// Objective-C runtime, and the delegate class is registered in it once.
const Objc = struct {
    getClass: *const fn ([*:0]const u8) callconv(.c) Id,
    getProtocol: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    registerName: *const fn ([*:0]const u8) callconv(.c) Sel,
    msgSend: *const fn () callconv(.c) void,
    allocateClassPair: *const fn (Id, [*:0]const u8, usize) callconv(.c) Id,
    registerClassPair: *const fn (Id) callconv(.c) void,
    addMethod: *const fn (Id, Sel, *const anyopaque, [*:0]const u8) callconv(.c) bool,
    addIvar: *const fn (Id, [*:0]const u8, usize, u8, [*:0]const u8) callconv(.c) bool,
    addProtocol: *const fn (Id, ?*anyopaque) callconv(.c) bool,
    instanceVariable: *const fn (Id, [*:0]const u8) callconv(.c) ?*anyopaque,
    getIvar: *const fn (Id, ?*anyopaque) callconv(.c) Id,
    setIvar: *const fn (Id, ?*anyopaque, Id) callconv(.c) void,
    poolPush: *const fn () callconv(.c) ?*anyopaque,
    poolPop: *const fn (?*anyopaque) callconv(.c) void,
    framework: *anyopaque = undefined,
    delegate: Id = null,
    link_ivar: ?*anyopaque = null,
};

const symbols = .{
    .{ "getClass", "objc_getClass" },
    .{ "getProtocol", "objc_getProtocol" },
    .{ "registerName", "sel_registerName" },
    .{ "msgSend", "objc_msgSend" },
    .{ "allocateClassPair", "objc_allocateClassPair" },
    .{ "registerClassPair", "objc_registerClassPair" },
    .{ "addMethod", "class_addMethod" },
    .{ "addIvar", "class_addIvar" },
    .{ "addProtocol", "class_addProtocol" },
    .{ "instanceVariable", "class_getInstanceVariable" },
    .{ "getIvar", "object_getIvar" },
    .{ "setIvar", "object_setIvar" },
    .{ "poolPush", "objc_autoreleasePoolPush" },
    .{ "poolPop", "objc_autoreleasePoolPop" },
};

var objc: Objc = undefined;
var objc_loaded = false;
var objc_lock: std.c.os_unfair_lock = .{};

/// The delegate's methods: selector, Objective-C type encoding, function. Each
/// takes the receiver and the selector first, as every method does.
const delegate_methods = .{
    .{ "centralManagerDidUpdateState:", "v@:@", &onState },
    .{ "centralManager:didDiscoverPeripheral:advertisementData:RSSI:", "v@:@@@@", &onDiscover },
    .{ "centralManager:didConnectPeripheral:", "v@:@@", &onConnect },
    .{ "centralManager:didFailToConnectPeripheral:error:", "v@:@@@", &onEnd },
    .{ "centralManager:didDisconnectPeripheral:error:", "v@:@@@", &onEnd },
    .{ "peripheral:didDiscoverServices:", "v@:@@", &onServices },
    .{ "peripheral:didDiscoverCharacteristicsForService:error:", "v@:@@@", &onCharacteristics },
    .{ "peripheral:didUpdateNotificationStateForCharacteristic:error:", "v@:@@@", &onNotifying },
    .{ "peripheral:didWriteValueForCharacteristic:error:", "v@:@@@", &onWritten },
    .{ "peripheral:didUpdateValueForCharacteristic:error:", "v@:@@@", &onValue },
};

fn load() !void {
    std.c.os_unfair_lock_lock(&objc_lock);
    defer std.c.os_unfair_lock_unlock(&objc_lock);
    if (objc_loaded) return;
    const runtime = std.c.dlopen("/usr/lib/libobjc.A.dylib", .{ .NOW = true }) orelse return error.BluetoothUnavailable;
    var loaded: Objc = undefined;
    inline for (symbols) |pair| {
        @field(loaded, pair[0]) = @ptrCast(@alignCast(std.c.dlsym(runtime, pair[1]) orelse return error.BluetoothUnavailable));
    }
    loaded.framework = std.c.dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", .{ .NOW = true }) orelse
        return error.BluetoothUnavailable;
    objc = loaded;

    const name = "NiimbenchBluetoothDelegate";
    if (objc.allocateClassPair(objc.getClass("NSObject"), name, 0)) |made| {
        _ = objc.addIvar(made, "link", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
        inline for (delegate_methods) |method| {
            _ = objc.addMethod(made, sel(method[0]), @ptrCast(method[2]), method[1]);
        }
        inline for (.{ "CBCentralManagerDelegate", "CBPeripheralDelegate" }) |protocol| {
            if (objc.getProtocol(protocol)) |p| _ = objc.addProtocol(made, p);
        }
        objc.registerClassPair(made);
    }
    objc.delegate = objc.getClass(name) orelse return error.BluetoothUnavailable;
    objc.link_ivar = objc.instanceVariable(objc.delegate, "link") orelse return error.BluetoothUnavailable;
    objc_loaded = true;
}

// ---- messages --------------------------------------------------------------

fn sel(name: [*:0]const u8) Sel {
    return objc.registerName(name);
}

fn class(name: [*:0]const u8) Id {
    return objc.getClass(name);
}

/// `[target name:args...]`. `objc_msgSend` has no prototype of its own: it is
/// called through the exact type of the method it reaches, which on arm64 is
/// the only way it gets its arguments in the right registers.
fn send(comptime R: type, target: Id, name: [*:0]const u8, args: anytype) R {
    const s = sel(name);
    return switch (args.len) {
        0 => @as(*const fn (Id, Sel) callconv(.c) R, @ptrCast(objc.msgSend))(target, s),
        1 => @as(*const fn (Id, Sel, @TypeOf(args[0])) callconv(.c) R, @ptrCast(objc.msgSend))(target, s, args[0]),
        2 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1])) callconv(.c) R, @ptrCast(objc.msgSend))(target, s, args[0], args[1]),
        3 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2])) callconv(.c) R, @ptrCast(objc.msgSend))(target, s, args[0], args[1], args[2]),
        4 => @as(*const fn (Id, Sel, @TypeOf(args[0]), @TypeOf(args[1]), @TypeOf(args[2]), @TypeOf(args[3])) callconv(.c) R, @ptrCast(objc.msgSend))(target, s, args[0], args[1], args[2], args[3]),
        else => @compileError("no message here takes more than four arguments"),
    };
}

fn string(text: [*:0]const u8) Id {
    return send(Id, class("NSString"), "stringWithUTF8String:", .{text});
}

/// The bytes of an NSString, valid while the string is. Empty for nil.
fn utf8(object: Id) []const u8 {
    if (object == null) return "";
    const text = send(?[*:0]const u8, object, "UTF8String", .{}) orelse return "";
    return std.mem.span(text);
}

fn uuid(text: [*:0]const u8) Id {
    return send(Id, class("CBUUID"), "UUIDWithString:", .{string(text)});
}

fn one(object: Id) Id {
    return send(Id, class("NSArray"), "arrayWithObject:", .{object});
}

fn count(list: Id) usize {
    if (list == null) return 0;
    return send(usize, list, "count", .{});
}

fn at(list: Id, index: usize) Id {
    return send(Id, list, "objectAtIndex:", .{index});
}

/// The first object in `list` whose `UUID` is `want`, such as a service or a
/// characteristic. CoreBluetooth spells a 128-bit UUID in capitals.
fn withUuid(list: Id, want: []const u8) Id {
    for (0..count(list)) |i| {
        const item = at(list, i);
        if (std.ascii.eqlIgnoreCase(utf8(send(Id, send(Id, item, "UUID", .{}), "UUIDString", .{})), want)) return item;
    }
    return null;
}

/// One of CoreBluetooth's exported `NSString *const` keys.
fn constant(name: [*:0]const u8) Id {
    const slot: *const Id = @ptrCast(@alignCast(std.c.dlsym(objc.framework, name) orelse return null));
    return slot.*;
}

// ---- the link ---------------------------------------------------------------

/// One central manager and what its delegate has seen. Everything below
/// `lock` is written on the dispatch queue and read by the waiting call.
const Link = struct {
    allocator: std.mem.Allocator,
    queue: ?*anyopaque,
    signal: ?*anyopaque,
    delegate: Id = null,
    manager: Id = null,
    peripheral: Id = null,
    lock: std.c.os_unfair_lock = .{},
    state: CBManagerState = .unknown,
    powered: bool = false,
    connected: bool = false,
    /// The connection failed or dropped. Every wait gives up on it.
    ended: bool = false,
    services: bool = false,
    service: Id = null,
    characteristics: bool = false,
    characteristic: Id = null,
    notifying: bool = false,
    written: bool = false,
    /// The last answer carried an NSError.
    refused: bool = false,
    inbound: std.ArrayList(u8) = .empty,
    unread: bool = false,
    /// Where a scan puts the printers it sees, while it runs.
    found: ?*discovery.Found = null,

    fn create(allocator: std.mem.Allocator) !*Link {
        const link = try allocator.create(Link);
        link.* = .{
            .allocator = allocator,
            .queue = dispatch_queue_create("niimbench.bluetooth", null),
            .signal = dispatch_semaphore_create(0),
        };
        link.delegate = send(Id, send(Id, objc.delegate, "alloc", .{}), "init", .{});
        objc.setIvar(link.delegate, objc.link_ivar, link);
        // The state arrives on the queue as soon as the manager exists, so the
        // delegate knows its link first.
        link.manager = send(Id, send(Id, class("CBCentralManager"), "alloc", .{}), "initWithDelegate:queue:", .{ link.delegate, link.queue });
        return link;
    }

    /// Hang up and free. No delegate method can reach the link afterwards:
    /// the delegates are cleared, then a no-op runs on the queue, which only
    /// returns once every callback queued before it has finished.
    fn destroy(link: *Link) void {
        if (link.peripheral) |peripheral| {
            if (link.characteristic != null and link.notifying) send(void, peripheral, "setNotifyValue:forCharacteristic:", .{ false, link.characteristic });
            send(void, link.manager, "cancelPeripheralConnection:", .{peripheral});
            send(void, peripheral, "setDelegate:", .{@as(Id, null)});
        }
        if (link.found != null) send(void, link.manager, "stopScan", .{});
        send(void, link.manager, "setDelegate:", .{@as(Id, null)});
        objc.setIvar(link.delegate, objc.link_ivar, null);
        dispatch_sync_f(link.queue, null, nothing);
        if (link.peripheral) |peripheral| send(void, peripheral, "release", .{});
        send(void, link.manager, "release", .{});
        send(void, link.delegate, "release", .{});
        dispatch_release(link.queue);
        dispatch_release(link.signal);
        link.inbound.deinit(link.allocator);
        link.allocator.destroy(link);
    }

    fn hold(link: *Link) void {
        std.c.os_unfair_lock_lock(&link.lock);
    }

    fn release(link: *Link) void {
        std.c.os_unfair_lock_unlock(&link.lock);
    }

    fn wake(link: *Link) void {
        _ = dispatch_semaphore_signal(link.signal);
    }

    /// Sleep until the delegate sets `event`, the link ends, or `ms` pass.
    fn wait(link: *Link, comptime event: []const u8, ms: u32) !void {
        const deadline = dispatch_time(0, @as(i64, ms) * std.time.ns_per_ms);
        while (true) {
            link.hold();
            const done = @field(link, event);
            const ended = link.ended;
            link.release();
            if (done) return;
            if (ended) return error.Disconnected;
            if (dispatch_semaphore_wait(link.signal, deadline) != 0) return error.BluetoothTimeout;
        }
    }

    fn wasRefused(link: *Link) bool {
        link.hold();
        defer link.release();
        return link.refused;
    }

    /// Wait for the radio, and name why it cannot be used if it cannot.
    fn powerOn(link: *Link) !void {
        try link.wait("powered", power_ms);
        return switch (link.state) {
            .powered_on => {},
            .unsupported => error.BluetoothUnsupported,
            .unauthorized => error.BluetoothNotAllowed,
            .powered_off => error.BluetoothOff,
            else => error.BluetoothUnavailable,
        };
    }
};

fn nothing(_: ?*anyopaque) callconv(.c) void {}

fn linkOf(self: Id) ?*Link {
    return @ptrCast(@alignCast(objc.getIvar(self, objc.link_ivar)));
}

// ---- the delegate ------------------------------------------------------------

fn onState(self: Id, _: Sel, central: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    const state: CBManagerState = @fromBackingInt(@intCast(send(isize, central, "state", .{})));
    link.hold();
    link.state = state;
    link.powered = state != .unknown and state != .resetting;
    link.release();
    link.wake();
}

fn onDiscover(self: Id, _: Sel, _: Id, peripheral: Id, advertisement: Id, _: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    // The advertised name is there before the peripheral's own is read.
    var name = utf8(send(Id, advertisement, "objectForKey:", .{constant("CBAdvertisementDataLocalNameKey")}));
    if (name.len == 0) name = utf8(send(Id, peripheral, "name", .{}));
    const address = utf8(send(Id, send(Id, peripheral, "identifier", .{}), "UUIDString", .{}));
    const services = send(Id, advertisement, "objectForKey:", .{constant("CBAdvertisementDataServiceUUIDsKey")});
    const le = withUuid(services, dbus.niimbot_le_service) != null;
    link.hold();
    defer link.release();
    if (link.found) |out| out.addNamed(address, name, .{ .le = le });
}

fn onConnect(self: Id, _: Sel, _: Id, _: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    link.hold();
    link.connected = true;
    link.release();
    link.wake();
}

fn onEnd(self: Id, _: Sel, _: Id, _: Id, _: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    link.hold();
    link.ended = true;
    link.release();
    link.wake();
}

fn onServices(self: Id, _: Sel, peripheral: Id, err: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    const service = withUuid(send(Id, peripheral, "services", .{}), dbus.niimbot_le_service);
    link.hold();
    link.service = service;
    link.refused = err != null;
    link.services = true;
    link.release();
    link.wake();
}

fn onCharacteristics(self: Id, _: Sel, _: Id, service: Id, err: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    const characteristic = withUuid(send(Id, service, "characteristics", .{}), dbus.niimbot_le_characteristic);
    link.hold();
    link.characteristic = characteristic;
    link.refused = err != null;
    link.characteristics = true;
    link.release();
    link.wake();
}

fn onNotifying(self: Id, _: Sel, _: Id, _: Id, err: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    link.hold();
    link.refused = err != null;
    link.notifying = true;
    link.release();
    link.wake();
}

fn onWritten(self: Id, _: Sel, _: Id, _: Id, err: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    link.hold();
    link.refused = err != null;
    link.written = true;
    link.release();
    link.wake();
}

/// A notification: the printer's answer, appended to what has not been read.
fn onValue(self: Id, _: Sel, _: Id, characteristic: Id, err: Id) callconv(.c) void {
    const link = linkOf(self) orelse return;
    if (err != null) return;
    const value = send(Id, characteristic, "value", .{});
    if (value == null) return;
    const len = send(usize, value, "length", .{});
    const bytes = send(?[*]const u8, value, "bytes", .{}) orelse return;
    link.hold();
    link.inbound.appendSlice(link.allocator, bytes[0..len]) catch {};
    link.unread = link.inbound.items.len > 0;
    link.release();
    link.wake();
}

// ---- the transport -------------------------------------------------------------

fn write(ptr: *anyopaque, data: []const u8) !void {
    const link: *Link = @ptrCast(@alignCast(ptr));
    const pool = objc.poolPush();
    defer objc.poolPop(pool);
    link.hold();
    link.written = false;
    link.refused = false;
    link.release();
    // One wire frame is far under the MTU, so a frame is one write, with a
    // response, as on BlueZ.
    const bytes = send(Id, class("NSData"), "dataWithBytes:length:", .{ @as(?*const anyopaque, data.ptr), data.len });
    send(void, link.peripheral, "writeValue:forCharacteristic:type:", .{ bytes, link.characteristic, write_with_response });
    try link.wait("written", write_ms);
    if (link.wasRefused()) return error.WriteRefused;
}

/// What the printer has notified, or zero after half a second of nothing,
/// which callers retry.
fn read(ptr: *anyopaque, buf: []u8) !usize {
    const link: *Link = @ptrCast(@alignCast(ptr));
    link.wait("unread", read_wait_ms) catch |err| switch (err) {
        error.BluetoothTimeout => return 0,
        else => return err,
    };
    link.hold();
    defer link.release();
    const n = @min(buf.len, link.inbound.items.len);
    @memcpy(buf[0..n], link.inbound.items[0..n]);
    link.inbound.replaceRangeAssumeCapacity(0, n, &.{});
    link.unread = link.inbound.items.len > 0;
    return n;
}

fn close(ptr: *anyopaque) void {
    const link: *Link = @ptrCast(@alignCast(ptr));
    const pool = objc.poolPush();
    defer objc.poolPop(pool);
    link.destroy();
}

/// Connect to the printer this Mac knows by `address`, the UUID a scan
/// reported, and return the transport that prints to it.
pub fn open(allocator: std.mem.Allocator, _: std.Io, address: []const u8) !printer.Transport {
    var text: [64:0]u8 = undefined;
    if (address.len >= text.len) return error.BadAddress;
    @memcpy(text[0..address.len], address);
    text[address.len] = 0;

    try load();
    const pool = objc.poolPush();
    defer objc.poolPop(pool);
    const link = try Link.create(allocator);
    errdefer link.destroy();
    try link.powerOn();

    const id = send(Id, send(Id, class("NSUUID"), "alloc", .{}), "initWithUUIDString:", .{string(&text)});
    if (id == null) return error.BadAddress;
    defer send(void, id, "release", .{});
    // A peripheral this Mac has seen, in a scan by this program or another.
    const known = send(Id, link.manager, "retrievePeripheralsWithIdentifiers:", .{one(id)});
    if (count(known) == 0) return error.PrinterNotSeen;
    link.peripheral = send(Id, at(known, 0), "retain", .{});
    send(void, link.peripheral, "setDelegate:", .{link.delegate});

    send(void, link.manager, "connectPeripheral:options:", .{ link.peripheral, @as(Id, null) });
    try link.wait("connected", connect_ms);
    send(void, link.peripheral, "discoverServices:", .{one(uuid(dbus.niimbot_le_service))});
    try link.wait("services", setup_ms);
    if (link.service == null) return error.PrintCharacteristicMissing;
    send(void, link.peripheral, "discoverCharacteristics:forService:", .{ one(uuid(dbus.niimbot_le_characteristic)), link.service });
    try link.wait("characteristics", setup_ms);
    if (link.characteristic == null) return error.PrintCharacteristicMissing;
    send(void, link.peripheral, "setNotifyValue:forCharacteristic:", .{ true, link.characteristic });
    try link.wait("notifying", setup_ms);
    if (link.wasRefused()) return error.NotifyRefused;

    return .{
        .ptr = link,
        .vtable = &.{ .write = write, .read = read, .close = close },
    };
}

/// The Niimbot printers nearby. With `discover` the radio listens for
/// `listen_ms`; without it the answer is the printers already connected to
/// this Mac, which is the nearest macOS has to BlueZ's paired list.
pub fn find(io: std.Io, allocator: std.mem.Allocator, discover: bool, listen_ms: u32, out: *discovery.Found) !void {
    try load();
    const pool = objc.poolPush();
    defer objc.poolPop(pool);
    const link = try Link.create(allocator);
    defer link.destroy();
    try link.powerOn();
    if (!discover) {
        const list = send(Id, link.manager, "retrieveConnectedPeripheralsWithServices:", .{one(uuid(dbus.niimbot_le_service))});
        for (0..count(list)) |i| {
            const peripheral = at(list, i);
            const address = utf8(send(Id, send(Id, peripheral, "identifier", .{}), "UUIDString", .{}));
            out.addNamed(address, utf8(send(Id, peripheral, "name", .{})), .{ .le = true });
        }
        return;
    }
    link.hold();
    link.found = out;
    link.release();
    send(void, link.manager, "scanForPeripheralsWithServices:options:", .{ @as(Id, null), @as(Id, null) });
    io.sleep(.fromMilliseconds(listen_ms), .awake) catch {};
}

// ---- checks that need no radio -------------------------------------------------

test "the runtime loads and the delegate class answers CoreBluetooth's selectors" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try load();
    const pool = objc.poolPush();
    defer objc.poolPop(pool);
    const delegate = send(Id, send(Id, objc.delegate, "alloc", .{}), "init", .{});
    defer send(void, delegate, "release", .{});
    inline for (delegate_methods) |method| {
        try std.testing.expect(send(bool, delegate, "respondsToSelector:", .{sel(method[0])}));
    }
    // CoreBluetooth spells a 128-bit UUID in capitals, which is why the
    // service is matched without regard to case.
    try std.testing.expectEqualStrings("E7810A71-73AE-499D-8C15-FAA9AEF0C3F2", utf8(send(Id, uuid(dbus.niimbot_le_service), "UUIDString", .{})));
}

test "a notification reaches read, in order, and a frame split in two is one answer" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try load();
    const pool = objc.poolPush();
    defer objc.poolPop(pool);
    // A characteristic made here stands in for the printer's; the delegate
    // method is sent to exactly as CoreBluetooth sends it.
    const characteristic = send(Id, send(Id, class("CBMutableCharacteristic"), "alloc", .{}), "initWithType:properties:value:permissions:", .{
        uuid(dbus.niimbot_le_characteristic), @as(usize, 0x10), @as(Id, null), @as(usize, 0x01),
    });
    defer send(void, characteristic, "release", .{});

    var link = Link{ .allocator = std.testing.allocator, .queue = null, .signal = dispatch_semaphore_create(0) };
    defer dispatch_release(link.signal);
    defer link.inbound.deinit(std.testing.allocator);
    const delegate = send(Id, send(Id, objc.delegate, "alloc", .{}), "init", .{});
    defer send(void, delegate, "release", .{});
    objc.setIvar(delegate, objc.link_ivar, &link);

    for ([_][]const u8{ &.{ 0x55, 0x55, 0x48 }, &.{ 0x02, 0x09, 0x00, 0x43, 0xaa, 0xaa } }) |part| {
        const value = send(Id, class("NSData"), "dataWithBytes:length:", .{ @as(?*const anyopaque, part.ptr), part.len });
        send(void, characteristic, "setValue:", .{value});
        send(void, delegate, "peripheral:didUpdateValueForCharacteristic:error:", .{ @as(Id, null), characteristic, @as(Id, null) });
    }
    var buf: [16]u8 = undefined;
    const n = try read(&link, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x55, 0x48, 0x02, 0x09, 0x00, 0x43, 0xaa, 0xaa }, buf[0..n]);
    // Nothing more arrived, so the next read waits its half second and says so.
    try std.testing.expectEqual(@as(usize, 0), try read(&link, &buf));
}

test "a scan answers, with the printers it heard or with why the radio cannot be used" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Like the BlueZ check, this asks the real stack. A Mac without a radio,
    // such as a CI machine, answers with the reason; a Mac with one listens
    // for half a second and may list a printer. Neither may crash or hang.
    var found = discovery.Found{};
    find(std.testing.io, std.testing.allocator, true, 500, &found) catch |err| switch (err) {
        error.BluetoothUnsupported, error.BluetoothNotAllowed, error.BluetoothOff, error.BluetoothUnavailable, error.BluetoothTimeout => {
            std.debug.print("bluetooth: {s}\n", .{@errorName(err)});
            return;
        },
        else => return err,
    };
    std.debug.print("bluetooth: {d} printer(s) heard\n", .{found.len});
}
