const std = @import("std");
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

pub const Opener = *const fn (allocator: std.mem.Allocator, addr: []const u8) anyerror!printer.Transport;

pub const Registry = struct {
    usb: ?Opener = null,
    bluetooth: ?Opener = null,

    pub fn open(self: Registry, conn: []const u8, allocator: std.mem.Allocator, addr: []const u8) !printer.Transport {
        if (std.mem.eql(u8, conn, "usb")) {
            const open_usb = self.usb orelse return error.UsbUnavailable;
            return open_usb(allocator, addr);
        }
        if (std.mem.eql(u8, conn, "bluetooth")) {
            const open_bt = self.bluetooth orelse return error.BluetoothUnavailable;
            return open_bt(allocator, addr);
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

pub fn openSerial(_: std.mem.Allocator, addr: []const u8) !printer.Transport {
    if (addr.len == 0 or std.mem.eql(u8, addr, "auto")) return error.AddressRequired;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, addr, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0);
    errdefer _ = std.os.linux.close(fd);
    try configureSerial(fd);
    return fdTransport(fd);
}

fn configureSerial(fd: std.posix.fd_t) !void {
    var tio: Termios = undefined;
    try ioctl(fd, TCGETS, @intFromPtr(&tio));
    tio.iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    tio.oflag &= ~OPOST;
    tio.lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    tio.cflag &= ~(CSIZE | PARENB | CSTOPB | CBAUD);
    tio.cflag |= CS8 | CLOCAL | CREAD | B115200;
    tio.cc[VMIN] = 0;
    tio.cc[VTIME] = 5;
    try ioctl(fd, TCSETS, @intFromPtr(&tio));
}

fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) !void {
    const rc = std.os.linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, fd))), request, arg);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.Termios;
}

const SockAddrRc = extern struct {
    family: u16,
    bdaddr: [6]u8,
    channel: u8,
};

pub fn openBluetooth(_: std.mem.Allocator, addr: []const u8) !printer.Transport {
    const mac = try parseMac(addr);
    const raw = std.os.linux.socket(31, std.os.linux.SOCK.STREAM, 3);
    const fd = try syscallFd(raw);
    errdefer _ = std.os.linux.close(fd);
    var sa = SockAddrRc{ .family = 31, .bdaddr = mac, .channel = 1 };
    const rc = std.os.linux.connect(fd, &sa, @sizeOf(SockAddrRc));
    _ = try syscallFd(rc);
    return fdTransport(fd);
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

fn syscallFd(rc: usize) !std.posix.fd_t {
    return @intCast(try transfer(rc));
}

fn transfer(rc: usize) !usize {
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        const err: std.os.linux.E = @enumFromInt(-signed);
        return std.posix.unexpectedErrno(err);
    }
    return @intCast(signed);
}

test "bluetooth addresses are stored reversed, like BlueZ str2ba" {
    const mac = try parseMac("AA:BB:CC:DD:EE:FF");
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA }, &mac);
}
