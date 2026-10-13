const std = @import("std");

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
    _ = @import("plugins.zig");
    _ = @import("server.zig");
}

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "print")) {
        try runPrint(init, args[2..]);
        return;
    }
    if (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "help"))) {
        try writeStdout(init.io, help_text);
        return;
    }
    try runServe(init, args[1..]);
}

const help_text =
    \\niimbench
    \\  serve the editor (default)
    \\    --port 8080
    \\    --no-open
    \\  print a PGM image
    \\    print --image label.pgm --addr /dev/ttyACM0 [--model b21] [--conn usb|bluetooth]
    \\          [--density 5] [--rotate 0|90|180|270]
    \\
;

fn runServe(init: std.process.Init, args: []const []const u8) !void {
    var open_browser = true;
    var port: u16 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--no-open")) {
            open_browser = false;
        } else if (std.mem.eql(u8, args[i], "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPort;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else {
            return error.UnknownArgument;
        }
    }

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

    var ctx = cordis.Context.init(init.gpa);
    defer ctx.deinit();
    try load.loadDefault(&ctx, init.io);
    const http = ctx.require(server.HttpService, "http");
    try http.printer.submit(init.io, http.transports.*, init.gpa, model, conn, addr, gray.pixels, gray.width, gray.height, density, degrees);
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
    const need = width * height;
    if (bytes.len - i < need) return error.BadPgm;
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
