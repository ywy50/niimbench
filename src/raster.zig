const std = @import("std");

/// Grayscale pixels, row-major, 0 = black, 255 = white.
/// Bit 1 in the packed row is a burned (black) dot: a pixel below 128 is
/// black, packed most significant bit first.
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

/// `PrintBitmapRow`'s header: the row number, three black-dot count bytes
/// left at zero, and how many times the printer repeats the row.
pub fn rowHeader(y: u16, repeat: u8) [6]u8 {
    return .{
        @intCast(y >> 8),
        @intCast(y & 0xFF),
        0,
        0,
        0,
        repeat,
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
    /// A D110 head that burns at density 1 to 5, where a D110 stops at 3.
    d110_m,

    pub fn maxWidth(self: Model) usize {
        return switch (self) {
            .b1, .b18, .b21 => 384,
            .d11, .d110, .d110_m => 96,
        };
    }

    pub fn maxDensity(self: Model) u8 {
        return switch (self) {
            .b18, .d11, .d110 => 3,
            else => 5,
        };
    }

    /// Dots the page must leave unused before the next gap. The gap sensor sits
    /// past the last row of the head, so a page that runs to the very end of
    /// the label leaves it no white space to find the gap in, and the printer
    /// keeps feeding until it ejects the following label blank. Two millimetres
    /// is enough on the D-series: on a D110_M with a 12x40 roll a 304-dot page
    /// prints and a 308-dot page over-feeds. The wider heads do not need it.
    pub fn pageMargin(self: Model) usize {
        return switch (self) {
            .d11, .d110, .d110_m => 2 * dots_per_mm,
            else => 0,
        };
    }

    /// The D-series page sequence clears the page buffer before each page and
    /// sets its copy count after the page size (`PrintClear`, `PrintQuantity`).
    /// Without them a D110_M kept a count and a buffer of its own: after idle
    /// it printed one page twice. The B-series sequences send neither.
    pub fn setsCopies(self: Model) bool {
        return switch (self) {
            .d11, .d110, .d110_m => true,
            else => false,
        };
    }

    pub fn parse(name: []const u8) !Model {
        inline for (@typeInfo(Model).@"enum".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) return @field(Model, field_name);
        }
        return error.UnknownModel;
    }
};

/// 203 dpi. These heads are not the 300 dpi Pro or D11H heads.
pub const dots_per_mm: usize = 8;

/// One die-cut roll. `width_mm` is across the print head and `height_mm` is the feed.
/// `models` is the printers that take this roll. B18 rolls are thermal transfer and
/// are not the D11 rolls, even when the millimetres match.
pub const LabelSize = struct {
    id: []const u8,
    width_mm: u16,
    height_mm: u16,
    round: bool = false,
    models: []const u8,
};

pub const label_sizes = [_]LabelSize{
    .{ .id = "12x22", .width_mm = 12, .height_mm = 22, .models = "d11 d110 d110_m" },
    .{ .id = "12x30", .width_mm = 12, .height_mm = 30, .models = "d11 d110 d110_m" },
    .{ .id = "12x40", .width_mm = 12, .height_mm = 40, .models = "d11 d110 d110_m" },
    .{ .id = "14x30", .width_mm = 14, .height_mm = 30, .models = "d11 d110 d110_m" },
    .{ .id = "14x40", .width_mm = 14, .height_mm = 40, .models = "d11 d110 d110_m" },
    .{ .id = "14x50", .width_mm = 14, .height_mm = 50, .models = "d11 d110 d110_m" },
    .{ .id = "14x60", .width_mm = 14, .height_mm = 60, .models = "d11 d110 d110_m" },
    .{ .id = "15x26", .width_mm = 15, .height_mm = 26, .models = "d11 d110 d110_m" },
    .{ .id = "15x30", .width_mm = 15, .height_mm = 30, .models = "d11 d110 d110_m" },
    .{ .id = "15x40", .width_mm = 15, .height_mm = 40, .models = "d11 d110 d110_m" },
    .{ .id = "15x50", .width_mm = 15, .height_mm = 50, .models = "d11 d110 d110_m" },
    .{ .id = "b18-10x25", .width_mm = 10, .height_mm = 25, .models = "b18" },
    .{ .id = "b18-12x30", .width_mm = 12, .height_mm = 30, .models = "b18" },
    .{ .id = "b18-14x30", .width_mm = 14, .height_mm = 30, .models = "b18" },
    .{ .id = "b18-14x40", .width_mm = 14, .height_mm = 40, .models = "b18" },
    .{ .id = "b18-14x50", .width_mm = 14, .height_mm = 50, .models = "b18" },
    .{ .id = "b18-14x60", .width_mm = 14, .height_mm = 60, .models = "b18" },
    .{ .id = "b18-14x120", .width_mm = 14, .height_mm = 120, .models = "b18" },
    .{ .id = "round20", .width_mm = 20, .height_mm = 20, .round = true, .models = "b1 b21" },
    .{ .id = "25x15", .width_mm = 25, .height_mm = 15, .models = "b1 b21" },
    .{ .id = "round30", .width_mm = 30, .height_mm = 30, .round = true, .models = "b1 b21" },
    .{ .id = "30x15", .width_mm = 30, .height_mm = 15, .models = "b1 b21" },
    .{ .id = "30x20", .width_mm = 30, .height_mm = 20, .models = "b1 b21" },
    .{ .id = "30x30", .width_mm = 30, .height_mm = 30, .models = "b1 b21" },
    .{ .id = "30x40", .width_mm = 30, .height_mm = 40, .models = "b1 b21" },
    .{ .id = "40x15", .width_mm = 40, .height_mm = 15, .models = "b1 b21" },
    .{ .id = "40x20", .width_mm = 40, .height_mm = 20, .models = "b1 b21" },
    .{ .id = "40x30", .width_mm = 40, .height_mm = 30, .models = "b1 b21" },
    .{ .id = "40x60", .width_mm = 40, .height_mm = 60, .models = "b1 b21" },
    .{ .id = "40x80", .width_mm = 40, .height_mm = 80, .models = "b1 b21" },
    .{ .id = "45x15", .width_mm = 45, .height_mm = 15, .models = "b1 b21" },
    .{ .id = "round50", .width_mm = 50, .height_mm = 50, .round = true, .models = "b1 b21" },
    .{ .id = "50x15", .width_mm = 50, .height_mm = 15, .models = "b1 b21" },
    .{ .id = "50x20", .width_mm = 50, .height_mm = 20, .models = "b1 b21" },
    .{ .id = "50x30", .width_mm = 50, .height_mm = 30, .models = "b1 b21" },
    .{ .id = "50x50", .width_mm = 50, .height_mm = 50, .models = "b1 b21" },
    .{ .id = "50x70", .width_mm = 50, .height_mm = 70, .models = "b1 b21" },
    .{ .id = "50x80", .width_mm = 50, .height_mm = 80, .models = "b1 b21" },
};

pub fn sizeFits(size: LabelSize, model: Model) bool {
    var it = std.mem.tokenizeScalar(u8, size.models, ' ');
    const name = @tagName(model);
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

pub fn sizePixels(size: LabelSize, model: Model) struct { width: usize, height: usize } {
    return .{
        .width = @min(@as(usize, size.width_mm) * dots_per_mm, model.maxWidth()),
        .height = @as(usize, size.height_mm) * dots_per_mm,
    };
}

/// The roll shipped with that model: D11 and D110_M 12×40, D110 15×30, B18 14×50, B1 and B21 50×30.
pub fn defaultLabelId(model: Model) []const u8 {
    return switch (model) {
        .b1, .b21 => "50x30",
        .b18 => "b18-14x50",
        .d11, .d110_m => "12x40",
        .d110 => "15x30",
    };
}

pub fn findLabelSize(id: []const u8) ?LabelSize {
    for (label_sizes) |size| {
        if (std.mem.eql(u8, size.id, id)) return size;
    }
    return null;
}

test "label sizes follow the model and stop at the print head" {
    const b21 = Model.b21;
    const roll = findLabelSize("50x30").?;
    try std.testing.expect(sizeFits(roll, b21));
    try std.testing.expect(sizeFits(roll, .b1));
    try std.testing.expect(!sizeFits(roll, .d11));
    try std.testing.expect(!sizeFits(roll, .b18));
    const wide = sizePixels(roll, b21);
    try std.testing.expectEqual(@as(usize, 384), wide.width);
    try std.testing.expectEqual(@as(usize, 240), wide.height);

    const forty = sizePixels(findLabelSize("40x30").?, b21);
    try std.testing.expectEqual(@as(usize, 320), forty.width);
    try std.testing.expectEqual(@as(usize, 240), forty.height);

    const d11_15 = findLabelSize("15x30").?;
    try std.testing.expect(sizeFits(d11_15, .d11));
    try std.testing.expect(sizeFits(d11_15, .d110));
    try std.testing.expect(!sizeFits(d11_15, .b21));
    const narrow = sizePixels(d11_15, .d11);
    try std.testing.expectEqual(@as(usize, 96), narrow.width);
    try std.testing.expectEqual(@as(usize, 240), narrow.height);

    const b18 = findLabelSize("b18-14x50").?;
    try std.testing.expect(sizeFits(b18, .b18));
    try std.testing.expect(!sizeFits(b18, .d11));
    const transfer = sizePixels(b18, .b18);
    try std.testing.expectEqual(@as(usize, 112), transfer.width);
    try std.testing.expectEqual(@as(usize, 400), transfer.height);

    inline for (@typeInfo(Model).@"enum".field_names) |name| {
        const model = @field(Model, name);
        const size = findLabelSize(defaultLabelId(model)).?;
        try std.testing.expect(sizeFits(size, model));
    }
}

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

test "the D-series pages leave the gap sensor a margin" {
    // A 12x40 roll is 320 dots tall. A print of all 320 leaves the gap sensor
    // nothing to find and the printer feeds the next label out blank, so a
    // print stops 16 dots (2 mm) short of the label it was laid out on.
    // Measured on a D110_M: 304 dots printed, 308 over-fed.
    try std.testing.expectEqual(@as(usize, 16), Model.d110.pageMargin());
    try std.testing.expectEqual(@as(usize, 16), Model.d11.pageMargin());
    try std.testing.expectEqual(@as(usize, 0), Model.b21.pageMargin());
    try std.testing.expectEqual(@as(usize, 304), sizePixels(findLabelSize("12x40").?, .d110).height - Model.d110.pageMargin());
}
