const std = @import("std");
const builtin = @import("builtin");

pub const packet = @import("packet.zig");
pub const cordis = @import("cordis.zig");
pub const load = @import("load.zig");
pub const raster = @import("raster.zig");
pub const server = @import("server.zig");

pub const default_patch = @import("load.zig").bundled_patch;

test {
    _ = @import("cordis.zig");
    _ = @import("packet.zig");
    _ = @import("raster.zig");
    _ = @import("printer.zig");
    _ = @import("patch.zig");
    _ = @import("device.zig");
    _ = @import("dbus.zig");
    _ = @import("discovery.zig");
    _ = @import("plugins.zig");
    _ = @import("server.zig");
    _ = @import("label.zig");
    _ = @import("example_source.zig");
    if (builtin.os.tag == .macos) _ = @import("corebluetooth.zig");
}

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "print")) {
        try runPrint(init, args[2..]);
        return;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "version"))) {
        try writeStdout(init.io, "niimbench " ++ version ++ "\n");
        return;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help"))) {
        try writeStdout(init.io, help_text);
        return;
    }
    try runServe(init, args[1..]);
}

/// The version in build.zig.zon, which is the only place it is written.
pub const version = @import("build_options").version;

test "the version is a semantic version" {
    _ = try std.SemanticVersion.parse(version);
}

const help_text =
    \\niimbench
    \\  serve the editor (default)
    \\    --port 8080
    \\    --no-open
    \\    --parent PID   die with PID, which must be this process's parent
    \\  print a PGM image
    \\    print --image label.pgm --addr /dev/ttyACM0 [--model b21] [--conn usb|bluetooth]
    \\          [--density 5] [--rotate 0|90|180|270]
    \\  print the version
    \\    --version
    \\
;

/// One server at a time, per checkout.
///
/// A stray server is not harmless: it holds a port, keeps its own session
/// token, and a page open on it looks like the page just built. Holding an
/// exclusive lock on a file in the working directory makes a second start fail
/// with a message that says what is already running, and the lock is released
/// by the kernel when the process ends however it ends, so there is no stale
/// lock to clean up.
const lock_path = ".niimbench.lock";

fn takeServeLock(io: std.Io) !std.Io.File {
    var file = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false });
    errdefer file.close(io);
    const got = file.tryLock(io, .exclusive) catch |err| switch (err) {
        error.FileLocksUnsupported => return file,
        else => return err,
    };
    if (!got) {
        var held: [1024]u8 = undefined;
        var reader = file.reader(io, &held);
        const text = reader.interface.allocRemaining(std.heap.page_allocator, .limited(1024)) catch "";
        defer if (text.len > 0) std.heap.page_allocator.free(text);
        std.debug.print(
            "niimbench is already serving{s}{s}\nStop it first, or use it: two servers means two tokens and two ports.\n",
            .{ if (text.len > 0) ": " else "", text },
        );
        return error.AlreadyServing;
    }
    try file.setLength(io, 0);
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "pid {d}\n", .{if (builtin.os.tag == .linux) std.os.linux.getpid() else std.c.getpid()}) catch "running\n";
    var writer = file.writer(io, &held_write_buffer);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
    return file;
}

var held_write_buffer: [256]u8 = undefined;

/// A server started for a check or by an agent dies with the process that
/// started it. The kernel sends it SIGKILL when its parent exits, however the
/// parent exits, so a harness killed outright, which never runs its cleanup,
/// still cannot leave a server behind. The lock above keeps one server per
/// directory; this keeps a throwaway one from outliving its owner.
///
/// `pid` must be the parent. It is checked after the request because the
/// parent may already be gone, and then the signal would never come.
///
/// macOS has no parent-death signal, so there a task watches the parent
/// instead and exits the server within a tenth of a second of it going.
fn dieWithParent(io: std.Io, pid: std.posix.pid_t) !void {
    if (builtin.os.tag != .linux) {
        if (std.c.getppid() != pid) return error.ParentGone;
        _ = try io.concurrent(watchParent, .{ io, pid });
        return;
    }
    const linux = std.os.linux;
    const rc = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    if (linux.errno(rc) != .SUCCESS) return error.ParentWatchFailed;
    if (linux.getppid() != pid) return error.ParentGone;
}

// ponytail: a poll, not kqueue's NOTE_EXIT; a tenth of a second is soon enough
// for a server a check started.
fn watchParent(io: std.Io, pid: std.posix.pid_t) void {
    while (std.c.getppid() == pid) io.sleep(.fromMilliseconds(100), .awake) catch return;
    std.process.exit(137);
}

fn runServe(init: std.process.Init, args: []const []const u8) !void {
    var open_browser = true;
    var port: u16 = 0;
    var parent: ?std.posix.pid_t = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-open")) {
            open_browser = false;
        } else if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPort;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--parent")) {
            i += 1;
            if (i >= args.len) return error.MissingParent;
            parent = try std.fmt.parseInt(std.posix.pid_t, args[i], 10);
        } else {
            return error.UnknownArgument;
        }
    }

    if (parent) |pid| try dieWithParent(init.io, pid);

    // Claim the single-server slot before the listener exists, so a second
    // start cannot get as far as binding. Being told the server is already
    // running is an answer, not a crash, so it exits quietly with a failure
    // status rather than unwinding a stack trace at whoever typed the command.
    var lock = takeServeLock(init.io) catch |err| switch (err) {
        error.AlreadyServing => std.process.exit(1),
        else => return err,
    };
    defer lock.close(init.io);

    var ctx = cordis.Context.init(init.gpa);
    defer ctx.deinit();
    ctx.http_port = port;
    try load.loadDefault(&ctx, init.io);
    const http = ctx.require(server.HttpService, "http");
    try server.serve(http, init.io, open_browser);
}

fn runPrint(init: std.process.Init, args: []const []const u8) !void {
    var image_path: ?[]const u8 = null;
    var addr: []const u8 = "";
    var model_name: []const u8 = "b21";
    var conn: []const u8 = "usb";
    var density: u8 = 5;
    var degrees: u16 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--image")) {
            i += 1;
            if (i >= args.len) return error.MissingImage;
            image_path = args[i];
        } else if (std.mem.eql(u8, arg, "--addr")) {
            i += 1;
            if (i >= args.len) return error.MissingAddress;
            addr = args[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModel;
            model_name = args[i];
        } else if (std.mem.eql(u8, arg, "--conn")) {
            i += 1;
            if (i >= args.len) return error.MissingConnection;
            conn = args[i];
        } else if (std.mem.eql(u8, arg, "--density")) {
            i += 1;
            if (i >= args.len) return error.MissingDensity;
            density = try std.fmt.parseInt(u8, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--rotate")) {
            i += 1;
            if (i >= args.len) return error.MissingRotate;
            degrees = try std.fmt.parseInt(u16, args[i], 10);
        } else return error.UnknownArgument;
    }
    const path = image_path orelse return error.MissingImage;
    const model = try raster.Model.parse(model_name);
    const gray = try readPgm(init.gpa, init.io, path);
    defer init.gpa.free(gray.pixels);

    // A raw PGM has no fields to turn, so `--rotate` turns the page itself.
    // That is the one place a whole page is rotated: a label body turns its
    // fields, each around its own centre, and the roll is never asked to turn.
    const turned = try server.rotated(init.gpa, .{
        .pixels = gray.pixels,
        .width = gray.width,
        .height = gray.height,
    }, degrees);
    defer init.gpa.free(turned.pixels);

    var ctx = cordis.Context.init(init.gpa);
    defer ctx.deinit();
    try load.loadDefault(&ctx, init.io);
    const http = ctx.require(server.HttpService, "http");
    try http.printer.submit(init.io, http.transports.*, init.gpa, model, conn, addr, turned.pixels, turned.width, turned.height, density, 1, null);
}

const Pgm = struct { pixels: []u8, width: usize, height: usize };

fn readPgm(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Pgm {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const bytes = try reader.interface.allocRemaining(allocator, .limited(8 << 20));
    defer allocator.free(bytes);
    return parsePgm(allocator, bytes);
}

fn parsePgm(allocator: std.mem.Allocator, bytes: []const u8) !Pgm {
    if (!std.mem.startsWith(u8, bytes, "P5")) return error.NotPgm;
    var i: usize = 2;
    const width = try pgmInt(bytes, &i);
    const height = try pgmInt(bytes, &i);
    const maxval = try pgmInt(bytes, &i);
    if (maxval != 255) return error.BadPgm;
    if (i >= bytes.len or (bytes[i] != '\n' and bytes[i] != ' ')) return error.BadPgm;
    i += 1;
    const remaining = bytes.len - i;
    // width*height must stay below remaining; the product itself may wrap and
    // pass a length check, which would then hand out a page the size never held.
    if (width != 0 and height > remaining / width) return error.BadPgm;
    const need = width * height;
    const pixels = try allocator.dupe(u8, bytes[i .. i + need]);
    return .{ .pixels = pixels, .width = width, .height = height };
}

fn pgmInt(bytes: []const u8, i: *usize) !usize {
    while (i.* < bytes.len and (bytes[i.*] == ' ' or bytes[i.*] == '\n' or bytes[i.*] == '\r' or bytes[i.*] == '\t')) i.* += 1;
    if (i.* < bytes.len and bytes[i.*] == '#') {
        while (i.* < bytes.len and bytes[i.*] != '\n') i.* += 1;
        return pgmInt(bytes, i);
    }
    const start = i.*;
    while (i.* < bytes.len and bytes[i.*] >= '0' and bytes[i.*] <= '9') i.* += 1;
    if (start == i.*) return error.BadPgm;
    return std.fmt.parseInt(usize, bytes[start..i.*], 10);
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    try stdout_file.interface.writeAll(text);
    try stdout_file.interface.flush();
}

test "parse a binary PGM" {
    const gpa = std.testing.allocator;
    const file = "P5\n2 1\n255\n\x00\xff";
    const gray = try parsePgm(gpa, file);
    defer gpa.free(gray.pixels);
    try std.testing.expectEqual(@as(usize, 2), gray.width);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255 }, gray.pixels);
}

test {
    _ = @import("labels_catalogue.zig");
}
