const std = @import("std");

/// Grayscale pixels, row-major, 0 = black, 255 = white.
/// Bit 1 in the packed row is a burned (black) dot, matching niimprint:
/// ImageOps.invert, then mode "1", then "1" when the pixel is not 0.
pub const Gray = struct {
    pixels: []u8,
    width: usize,
    height: usize,
};

pub fn packedRowBytes(width: usize) usize {
    return (width + 7) / 8;
}

pub fn packRow(pixels: []const u8, out: []u8) void {
    @memset(out, 0);
    for (pixels, 0..) |pixel, x| {
        if (pixel < 128) {
            out[x / 8] |= @as(u8, 1) << @intCast(7 - (x % 8));
        }
    }
}

pub fn rowHeader(y: u16) [6]u8 {
    return .{
        @intCast(y >> 8),
        @intCast(y & 0xFF),
        0,
        0,
        0,
        1,
    };
}

/// Clockwise rotation in the image plane (y grows downward), matching
/// Pillow's `rotate(-degrees)`.
pub fn rotate(gpa: std.mem.Allocator, pixels: []const u8, width: usize, height: usize, degrees: u16) !Gray {
    if (pixels.len != width * height) return error.BadSize;
    const turns = @divTrunc(degrees, 90);
    if (turns * 90 != degrees or turns > 3) return error.BadRotation;
    if (turns == 0) {
        const copy = try gpa.dupe(u8, pixels);
        return .{ .pixels = copy, .width = width, .height = height };
    }
    const swap = turns == 1 or turns == 3;
    const new_w = if (swap) height else width;
    const new_h = if (swap) width else height;
    const out = try gpa.alloc(u8, pixels.len);
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = pixels[y * width + x];
            const nx, const ny = switch (turns) {
                1 => .{ y, width - 1 - x },
                2 => .{ width - 1 - x, height - 1 - y },
                3 => .{ height - 1 - y, x },
                else => unreachable,
            };
            out[ny * new_w + nx] = pixel;
        }
    }
    return .{ .pixels = out, .width = new_w, .height = new_h };
}

pub const Model = enum {
    b1,
    b18,
    b21,
    d11,
    d110,

    pub fn maxWidth(self: Model) usize {
        return switch (self) {
            .b1, .b18, .b21 => 384,
            .d11, .d110 => 96,
        };
    }

    pub fn maxDensity(self: Model) u8 {
        return switch (self) {
            .b18, .d11, .d110 => 3,
            else => 5,
        };
    }

    pub fn parse(name: []const u8) !Model {
        inline for (@typeInfo(Model).@"enum".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) return @field(Model, field_name);
        }
        return error.UnknownModel;
    }
};

test "black pixels pack to burned bits" {
    const row = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var packed_row: [1]u8 = undefined;
    packRow(&row, &packed_row);
    try std.testing.expectEqual(@as(u8, 0xFF), packed_row[0]);
}

test "white pixels pack to empty bits" {
    const row = [_]u8{ 255, 255, 255, 255, 255, 255, 255, 255 };
    var packed_row: [1]u8 = undefined;
    packRow(&row, &packed_row);
    try std.testing.expectEqual(@as(u8, 0), packed_row[0]);
}

test "clockwise rotation matches the paper turn" {
    const gpa = std.testing.allocator;
    const pixels = [_]u8{ 1, 2 };
    const turned = try rotate(gpa, &pixels, 2, 1, 90);
    defer gpa.free(turned.pixels);
    try std.testing.expectEqual(@as(usize, 1), turned.width);
    try std.testing.expectEqual(@as(usize, 2), turned.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 2, 1 }, turned.pixels);
}
