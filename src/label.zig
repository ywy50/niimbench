const std = @import("std");
const raster = @import("raster.zig");
const font = @import("font.zig");

/// Where a while (lines.next()) |line| widest = @max(widest, lineWidth(face, line, size)); sits relative to its `x`. `center` and `right` move the line
/// back by half or all of its own width, so a wider value from a source stays
/// inside the label without the editor knowing how wide it will be.
pub const Align = enum {
    left,
    center,
    right,

    pub fn parse(name: []const u8) !Align {
        return std.meta.stringToEnum(Align, name) orelse error.BadAlign;
    }

    /// The left edge of a line of `text_width` at this alignment. It can be
    /// left of the label, where the line is clipped like at any other edge.
    /// Clamping it to 0 moved the ink away from the editor's box, and a turned
    /// field, whose upright line may be far longer than the roll is wide,
    /// jumped along the roll as soon as it grew.
    pub fn place(self: Align, x: isize, text_width: usize) isize {
        const width: isize = @intCast(text_width);
        return switch (self) {
            .left => x,
            .center => x - @divFloor(width, 2),
            .right => x - width,
        };
    }
};

/// One piece of text on a label. `key`, when set, is looked up in the source
/// JSON and replaces `text`. Coordinates are pixels from the top left.
pub const Field = struct {
    text: []const u8 = "",
    key: []const u8 = "",
    /// The anchor `align_mode` names: the block's left edge, centre or right
    /// edge. Signed, because a left-aligned block can start left of the label:
    /// a field turned on a narrow roll does, and changing its alignment must
    /// not move it.
    x: isize = 0,
    y: usize = 0,
    /// Line height in dots, any whole number from 1 to `max_size`. A line of
    /// text is exactly this tall, descenders included.
    size: usize = 16,
    /// `align` is a Zig keyword, so the field carries the mode's name.
    align_mode: Align = .left,
    /// Clockwise degrees, y down. 0 is upright. The block turns around its centre.
    rotation: i32 = 0,
    /// Which embedded typeface the letters are drawn in, by id: one of
    /// `font.fonts`. An id this build does not carry is `error.UnknownFont`.
    font: []const u8 = font.default_id,
    /// Accepted from older callers and ignored: `rotation` turns a field.
    direction: u16 = 0,
};

/// The largest line height a field may ask for. Larger sizes draw at this one.
pub const max_size = 1024;

fn dots(size: usize) usize {
    return std.math.clamp(size, 1, max_size);
}

/// White label with black text. `source_json` is a flat object. An empty
/// string means fields use their literal `text` only.
pub fn render(
    gpa: std.mem.Allocator,
    width: usize,
    height: usize,
    fields: []const Field,
    source_json: []const u8,
) !raster.Gray {
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return error.BadSize;
    const pixels = try gpa.alloc(u8, width * height);
    errdefer gpa.free(pixels);
    @memset(pixels, 255);
    try drawFields(gpa, pixels, width, height, fields, source_json);
    return .{ .pixels = pixels, .width = width, .height = height };
}

/// Draw `fields` on top of an existing grayscale buffer of `width * height`.
/// Text that runs past an edge is clipped, not wrapped: the field origin is
/// the only placement the label body carries.
pub fn renderOnto(
    gpa: std.mem.Allocator,
    background: []const u8,
    width: usize,
    height: usize,
    fields: []const Field,
    source_json: []const u8,
) !raster.Gray {
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return error.BadSize;
    if (background.len != width * height) return error.BadSize;
    const pixels = try gpa.dupe(u8, background);
    errdefer gpa.free(pixels);
    try drawFields(gpa, pixels, width, height, fields, source_json);
    return .{ .pixels = pixels, .width = width, .height = height };
}

fn drawFields(gpa: std.mem.Allocator, pixels: []u8, width: usize, height: usize, fields: []const Field, source_json: []const u8) !void {
    for (fields) |field| {
        const text = try resolve(gpa, field, source_json);
        defer gpa.free(text);
        // A line with nothing to draw draws nothing. Testing for an empty slice
        // is not enough: a field whose text is a space, or whose only lines are
        // blank, has no ink either, and the editor must not box a field that
        // puts nothing on the label.
        if (std.mem.trim(u8, text, "\n\r\t ").len == 0) continue;
        try drawText(gpa, pixels, width, height, field, text);
    }
}

/// A newline starts the next line. `text` may therefore hold several lines,
/// and every measurement below is about the whole block.
pub fn lineCount(text: []const u8) usize {
    var count: usize = 1;
    for (text) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}

/// The face a field names, or `error.UnknownFont` for a name this build does
/// not carry. Drawing an unknown font in some other one would print a label
/// that does not look like the one that was asked for.
pub fn faceOf(field: Field) !*const Face {
    return font.find(field.font) orelse error.UnknownFont;
}

pub const Face = font.Face;

/// Width in pixels of one line: the font's advances, rounded up to a dot.
pub fn lineWidth(face: *const Face, text: []const u8, size: usize) usize {
    return font.lineWidth(face, text, dots(size));
}

/// Width of the widest line in `text`, so a block is as wide as its longest
/// line. Alignment uses this: the lines share one anchor.
pub fn blockWidth(face: *const Face, text: []const u8, size: usize) usize {
    var widest: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| widest = @max(widest, lineWidth(face, line, size));
    return widest;
}

/// Height of every line in `text`. Lines stack `size` dots apart, so a block
/// of three lines at 20 is 60 dots tall.
pub fn blockHeight(text: []const u8, size: usize) usize {
    return lineCount(text) * dots(size);
}

/// False when the block would be clipped at the right or bottom edge.
pub fn textFits(face: *const Face, text: []const u8, size: usize, x: usize, y: usize, width: usize, height: usize) bool {
    return x + blockWidth(face, text, size) <= width and y + blockHeight(text, size) <= height;
}

/// The left edge of this field's block. `resolve` and this agree on the text,
/// so the ink and the editor's box are placed from one measurement.
pub fn alignedX(gpa: std.mem.Allocator, field: Field, source_json: []const u8) !isize {
    const text = try resolve(gpa, field, source_json);
    defer gpa.free(text);
    return field.align_mode.place(field.x, blockWidth(try faceOf(field), text, field.size));
}

fn resolve(gpa: std.mem.Allocator, field: Field, source_json: []const u8) ![]u8 {
    if (field.key.len == 0) return gpa.dupe(u8, field.text);
    if (source_json.len == 0) return gpa.dupe(u8, "");
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, source_json, .{}) catch return error.BadSource;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadSource;
    const value = parsed.value.object.get(field.key) orelse return gpa.dupe(u8, "");
    return switch (value) {
        .string => |s| gpa.dupe(u8, s),
        .number_string => |s| gpa.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(gpa, "{d}", .{n}),
        .float => |n| std.fmt.allocPrint(gpa, "{d}", .{n}),
        .bool => |b| gpa.dupe(u8, if (b) "true" else "false"),
        .null => gpa.dupe(u8, ""),
        .array, .object => gpa.dupe(u8, ""),
    };
}

/// The upright block is drawn into a grid of its own, then put on the label
/// through the field's turn. The grid is wider than the block by `margin` on
/// every side, because a glyph's ink may overhang its advance box.
fn drawText(gpa: std.mem.Allocator, pixels: []u8, width: usize, height: usize, field: Field, text: []const u8) !void {
    const size = dots(field.size);
    const face = try faceOf(field);
    const bw = blockWidth(face, text, size);
    const bh = blockHeight(text, size);
    if (bw == 0) return;
    const margin = size / 2 + 2;
    // A block bigger than the largest label could not be shown anyway.
    if ((bw + 2 * margin) * (bh + 2 * margin) > 4096 * 4096) return error.TextTooLarge;

    // Each letter's outline is turned about the block's centre before it is
    // filled, so a stroke is put on the dots once. Filling the block upright
    // and then turning its dots put every stroke on the dots twice, and at
    // most angles a thin one came out stepped and broken.
    //
    // The block is drawn into a grid of its own, at the same coordinates
    // whatever the angle, and the grid is then laid on the label a whole
    // number of dots away. Drawing at the label's own coordinates instead moved
    // a dot or two of upright text, because a sum of floats rounds differently
    // at a different offset. Turned, the block reaches no farther from its
    // centre than half the diagonal of its upright grid, so the grid is padded
    // to that on each side.
    const turned = @mod(field.rotation, 360) != 0;
    const upright_w = bw + 2 * margin;
    const upright_h = bh + 2 * margin;
    const diagonal: usize = if (turned) @intFromFloat(@ceil(std.math.hypot(@as(f32, @floatFromInt(upright_w)), @as(f32, @floatFromInt(upright_h))))) else 0;
    const pad_x = if (turned) (diagonal - @min(diagonal, upright_w)) / 2 + 1 else 0;
    const pad_y = if (turned) (diagonal - @min(diagonal, upright_h)) / 2 + 1 else 0;
    const gw = upright_w + 2 * pad_x;
    const gh = upright_h + 2 * pad_y;
    const grid = try gpa.alloc(u8, gw * gh);
    defer gpa.free(grid);
    @memset(grid, 0);

    const left = field.align_mode.place(field.x, bw);
    const radians = @as(f32, @floatFromInt(@mod(field.rotation, 360))) * std.math.pi / 180.0;
    const turn: font.Turn = if (!turned) .{} else .{
        .cx = @as(f32, @floatFromInt(margin + pad_x)) + @as(f32, @floatFromInt(bw)) / 2.0,
        .cy = @as(f32, @floatFromInt(margin + pad_y)) + @as(f32, @floatFromInt(bh)) / 2.0,
        .cos = @cos(radians),
        .sin = @sin(radians),
    };
    var top: usize = margin + pad_y;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const line_left = field.align_mode.place(field.x, lineWidth(face, line, size));
        const at: f32 = @floatFromInt(line_left - left + @as(isize, @intCast(margin + pad_x)));
        try font.drawLine(gpa, face, grid, gw, at, @floatFromInt(top), size, line, turn);
        top += size;
    }

    // The grid's (0, 0) on the label.
    const ox = left - @as(isize, @intCast(margin + pad_x));
    const oy = @as(isize, @intCast(field.y)) - @as(isize, @intCast(margin + pad_y));
    for (0..gh) |gy| {
        const y = oy + @as(isize, @intCast(gy));
        if (y < 0 or y >= height) continue;
        for (0..gw) |gx| {
            const x = ox + @as(isize, @intCast(gx));
            if (x < 0 or x >= width or grid[gy * gw + gx] == 0) continue;
            pixels[@as(usize, @intCast(y)) * width + @as(usize, @intCast(x))] = 0;
        }
    }
}

/// One-pixel rectangle with every fourth pixel left out. The editor lays these
/// over the preview to mark fields, so they must be readable but not look like
/// label ink. Pixels outside the label are dropped.
pub fn rect(pixels: []u8, width: usize, height: usize, x0: usize, y0: usize, w: usize, h: usize, shade: u8) void {
    if (w == 0 or h == 0) return;
    const x1 = x0 + w - 1;
    const y1 = y0 + h - 1;
    var x = x0;
    while (x <= x1) : (x += 1) {
        if ((x - x0) % 4 == 3) continue;
        plot(pixels, width, height, x, y0, shade);
        plot(pixels, width, height, x, y1, shade);
    }
    var y = y0;
    while (y <= y1) : (y += 1) {
        if ((y - y0) % 4 == 3) continue;
        plot(pixels, width, height, x0, y, shade);
        plot(pixels, width, height, x1, y, shade);
    }
}

fn plot(pixels: []u8, width: usize, height: usize, x: usize, y: usize, shade: u8) void {
    if (x >= width or y >= height) return;
    pixels[y * width + x] = shade;
}

test "a source key draws the same ink as its literal value" {
    const gpa = std.testing.allocator;
    const literal = try render(gpa, 80, 24, &.{.{ .text = "NB-1", .x = 1, .y = 1 }}, "");
    defer gpa.free(literal.pixels);
    const filled = try render(gpa, 80, 24, &.{.{ .key = "sku", .x = 1, .y = 1 }}, "{\"sku\":\"NB-1\"}");
    defer gpa.free(filled.pixels);
    try std.testing.expectEqualSlices(u8, literal.pixels, filled.pixels);
    try std.testing.expect(inkCount(filled.pixels) > 0);
}

test "a numeric source value draws as decimal text" {
    const gpa = std.testing.allocator;
    const literal = try render(gpa, 40, 20, &.{.{ .text = "12", .x = 0, .y = 0 }}, "");
    defer gpa.free(literal.pixels);
    const filled = try render(gpa, 40, 20, &.{.{ .key = "n", .x = 0, .y = 0 }}, "{\"n\":12}");
    defer gpa.free(filled.pixels);
    try std.testing.expectEqualSlices(u8, literal.pixels, filled.pixels);
}

test "different source values draw different labels" {
    const gpa = std.testing.allocator;
    const source = "{\"sku\":\"NB-1\",\"title\":\"Niimbench\"}";
    const sku = try render(gpa, 120, 24, &.{.{ .key = "sku", .x = 1, .y = 1 }}, source);
    defer gpa.free(sku.pixels);
    const title = try render(gpa, 120, 24, &.{.{ .key = "title", .x = 1, .y = 1 }}, source);
    defer gpa.free(title.pixels);
    try std.testing.expect(!std.mem.eql(u8, sku.pixels, title.pixels));
}

test "text is placed at the field origin" {
    const gpa = std.testing.allocator;
    const low = try render(gpa, 40, 40, &.{.{ .text = "A", .x = 0, .y = 0, .size = 16 }}, "");
    defer gpa.free(low.pixels);
    const high = try render(gpa, 40, 40, &.{.{ .text = "A", .x = 0, .y = 20, .size = 16 }}, "");
    defer gpa.free(high.pixels);
    try std.testing.expect(inkCount(low.pixels[0 .. 40 * 16]) > 0);
    try std.testing.expectEqual(@as(usize, 0), inkCount(high.pixels[0 .. 40 * 20]));
    try std.testing.expect(inkCount(high.pixels[40 * 20 ..]) > 0);
}

test "text is stamped onto a background without erasing the rest" {
    const gpa = std.testing.allocator;
    var background: [40 * 20]u8 = undefined;
    @memset(&background, 200);
    const drawn = try renderOnto(gpa, &background, 40, 20, &.{.{ .text = "A", .x = 0, .y = 0 }}, "");
    defer gpa.free(drawn.pixels);
    try std.testing.expect(inkCount(drawn.pixels) > 0);
    try std.testing.expectEqual(@as(u8, 200), drawn.pixels[19 * 40 + 39]);
}

fn inkCount(pixels: []const u8) usize {
    var n: usize = 0;
    for (pixels) |pixel| {
        if (pixel == 0) n += 1;
    }
    return n;
}

test "a size is the line height, and lines stack by it" {
    try std.testing.expectEqual(@as(usize, 1), lineCount("AB"));
    try std.testing.expectEqual(@as(usize, 2), lineCount("AB\nCD"));
    try std.testing.expectEqual(@as(usize, 3), lineCount("A\n\nC"));
    try std.testing.expectEqual(@as(usize, 20), blockHeight("AB", 20));
    try std.testing.expectEqual(@as(usize, 40), blockHeight("AB\nCD", 20));
    // Any whole size, not a ladder: 17 sits between 16 and 18.
    try std.testing.expect(blockWidth(sans, "NIIMBENCH", 17) > blockWidth(sans, "NIIMBENCH", 16));
    try std.testing.expect(blockWidth(sans, "NIIMBENCH", 17) < blockWidth(sans, "NIIMBENCH", 18));
    // The block is as wide as its widest line.
    try std.testing.expectEqual(lineWidth(sans, "ABC", 16), blockWidth(sans, "A\nABC\nAB", 16));

    // The ink lands on the second line, and a blank line advances without drawing.
    const gpa = std.testing.allocator;
    const drawn = try render(gpa, 60, 60, &.{.{ .text = "AB\nCD", .x = 2, .y = 0, .size = 20 }}, "");
    defer gpa.free(drawn.pixels);
    try std.testing.expect(inkCount(drawn.pixels[0 .. 60 * 20]) > 0);
    try std.testing.expect(inkCount(drawn.pixels[60 * 20 .. 60 * 40]) > 0);
    const spaced = try render(gpa, 60, 60, &.{.{ .text = "A\n\nB", .x = 2, .y = 0, .size = 20 }}, "");
    defer gpa.free(spaced.pixels);
    try std.testing.expectEqual(@as(usize, 0), inkCount(spaced.pixels[60 * 20 .. 60 * 40]));
}

test "each line of a block is aligned on the shared anchor" {
    const gpa = std.testing.allocator;
    // Right and centre place every line by that line's own width, so a short
    // line does not sit flush with a long one.
    const text = "WIDE\nI";
    const left = try render(gpa, 100, 40, &.{.{ .text = text, .x = 70, .y = 0, .align_mode = .left }}, "");
    defer gpa.free(left.pixels);
    const right = try render(gpa, 100, 40, &.{.{ .text = text, .x = 70, .y = 0, .align_mode = .right }}, "");
    defer gpa.free(right.pixels);
    try std.testing.expect(!std.mem.eql(u8, left.pixels, right.pixels));
    const first_line = firstInkColumnIn(right.pixels, 100, 0, 16).?;
    const second_line = firstInkColumnIn(right.pixels, 100, 16, 32).?;
    try std.testing.expect(second_line > first_line);
}

test "the block is what decides the clip" {
    const one = blockWidth(sans, "AB", 16);
    try std.testing.expect(textFits(sans, "AB", 16, 0, 0, one, 16));
    try std.testing.expect(!textFits(sans, "AB", 16, 0, 0, one - 1, 16));
    // Two lines need 32 pixels, so 16 is not enough even though one line fits.
    try std.testing.expect(!textFits(sans, "AB\nCD", 16, 0, 0, 100, 16));
    try std.testing.expect(textFits(sans, "AB\nCD", 16, 0, 0, 100, 32));
}

/// Leftmost column with ink between two rows, exclusive of the end.
fn firstInkColumnIn(pixels: []const u8, width: usize, top: usize, bottom: usize) ?usize {
    for (0..width) |x| {
        for (top..bottom) |y| {
            if (pixels[y * width + x] == 0) return x;
        }
    }
    return null;
}

test "alignment places a line by its own width" {
    try std.testing.expectEqual(@as(isize, 10), Align.left.place(10, 40));
    try std.testing.expectEqual(@as(isize, -10), Align.center.place(10, 40));
    try std.testing.expectEqual(@as(isize, -30), Align.right.place(10, 40));
    try std.testing.expectEqual(@as(isize, 75), Align.center.place(100, 50));
    try std.testing.expectEqual(@as(isize, 50), Align.right.place(100, 50));
    // A line wider than twice its anchor starts left of the label, where it is
    // clipped like at any other edge. It is not pushed back on: that moves the
    // ink away from the box the editor draws round it.
    try std.testing.expectEqual(@as(isize, -196), Align.center.place(4, 400));
    try std.testing.expectEqual(@as(isize, -396), Align.right.place(4, 400));

    try std.testing.expectEqual(Align.center, try Align.parse("center"));
    try std.testing.expectEqual(Align.right, try Align.parse("right"));
    try std.testing.expectEqual(Align.left, try Align.parse("left"));
    try std.testing.expectError(error.BadAlign, Align.parse("middle"));
}

test "alignment moves the ink by the block width and keeps it on the label" {
    const gpa = std.testing.allocator;
    const text = "NB-1";
    const label_width = 200;
    const anchor = 120;
    const tall = 24;
    const bw = blockWidth(sans, text, 20);

    const left = try render(gpa, label_width, tall, &.{.{ .text = text, .x = anchor, .y = 2, .size = 20 }}, "");
    defer gpa.free(left.pixels);
    const center = try render(gpa, label_width, tall, &.{.{ .text = text, .x = anchor, .y = 2, .size = 20, .align_mode = .center }}, "");
    defer gpa.free(center.pixels);
    const right = try render(gpa, label_width, tall, &.{.{ .text = text, .x = anchor, .y = 2, .size = 20, .align_mode = .right }}, "");
    defer gpa.free(right.pixels);

    // The same ink, moved back by half or all of the block.
    const left_x = firstInkColumn(left.pixels, label_width, tall).?;
    try std.testing.expectEqual(left_x - bw / 2, firstInkColumn(center.pixels, label_width, tall).?);
    try std.testing.expectEqual(left_x - bw, firstInkColumn(right.pixels, label_width, tall).?);

    // Anchoring at the right edge still keeps the whole line on the label.
    const edge = try render(gpa, label_width, tall, &.{.{ .text = text, .x = label_width, .y = 2, .size = 20, .align_mode = .right }}, "");
    defer gpa.free(edge.pixels);
    const last = lastInkColumn(edge.pixels, label_width, tall).?;
    try std.testing.expect(last < label_width and last > label_width - 4);
}

/// Rightmost column that carries ink, or null for a blank page.
fn lastInkColumn(pixels: []const u8, width: usize, height: usize) ?usize {
    var x = width;
    while (x > 0) {
        x -= 1;
        for (0..height) |y| {
            if (pixels[y * width + x] == 0) return x;
        }
    }
    return null;
}

/// Leftmost column that carries ink, or null for a blank page.
fn firstInkColumn(pixels: []const u8, width: usize, height: usize) ?usize {
    for (0..width) |x| {
        for (0..height) |y| {
            if (pixels[y * width + x] == 0) return x;
        }
    }
    return null;
}

test "alignedX agrees with the drawn left edge" {
    const gpa = std.testing.allocator;
    const text = "AB";
    const size = 30;
    const label_width = 100 + blockWidth(sans, text, size) + 10;
    const anchor = 100;
    // A glyph starts a little after its pen position. Measuring that gap once
    // at x = 0 keeps the check about alignment rather than about the font.
    const at_zero = try render(gpa, label_width, size, &.{.{ .text = text, .x = 0, .y = 0, .size = size }}, "");
    defer gpa.free(at_zero.pixels);
    const gap = firstInkColumn(at_zero.pixels, label_width, size).?;
    for ([_]Align{ .left, .center, .right }) |mode| {
        const field = Field{ .text = text, .x = anchor, .y = 0, .size = size, .align_mode = mode };
        const placed = try alignedX(gpa, field, "");
        const drawn = try render(gpa, label_width, size, &.{field}, "");
        defer gpa.free(drawn.pixels);
        try std.testing.expectEqual(placed + @as(isize, @intCast(gap)), @as(isize, @intCast(firstInkColumn(drawn.pixels, label_width, size).?)));
    }
    // A source value is measured after resolution, not before.
    const keyed = Field{ .key = "sku", .x = anchor, .y = 0, .align_mode = .right };
    const resolved = try alignedX(gpa, keyed, "{\"sku\":\"NB-1\"}");
    const literal = try alignedX(gpa, .{ .text = "NB-1", .x = anchor, .align_mode = .right }, "");
    try std.testing.expectEqual(literal, resolved);
}

test "the ink stays inside the measured block" {
    const gpa = std.testing.allocator;
    const text = "NIIMBENCH";
    const size = 24;
    const width = blockWidth(sans, text, size);
    const drawn = try render(gpa, width + 8, size + 8, &.{.{ .text = text, .x = 0, .y = 0, .size = size }}, "");
    defer gpa.free(drawn.pixels);
    const last = lastInkColumn(drawn.pixels, drawn.width, drawn.height).?;
    try std.testing.expect(last < width);
    for (size..drawn.height) |y| {
        for (0..drawn.width) |x| {
            if (drawn.pixels[y * drawn.width + x] == 0) return error.InkBelowTheLine;
        }
    }
}

test "text past the right or bottom edge is clipped instead of wrapped" {
    const gpa = std.testing.allocator;
    const text = "CLIPPED";
    try std.testing.expect(blockWidth(sans, text, 16) > 40);
    const narrow = try render(gpa, 40, 30, &.{.{ .text = text, .x = 0, .y = 0, .size = 16 }}, "");
    defer gpa.free(narrow.pixels);
    // Clipping means the first line keeps ink and nothing wraps onto a second.
    try std.testing.expectEqual(@as(usize, 0), inkCount(narrow.pixels[16 * 40 ..]));
    try std.testing.expect(inkCount(narrow.pixels) > 0);
    try std.testing.expect(!textFits(sans, text, 16, 0, 0, 40, 30));
    try std.testing.expect(textFits(sans, "OK", 16, 0, 0, 40, 30));
}

test "the selection rectangle outlines without filling" {
    const gpa = std.testing.allocator;
    const pixels = try gpa.alloc(u8, 20 * 10);
    defer gpa.free(pixels);
    @memset(pixels, 255);
    rect(pixels, 20, 10, 2, 3, 8, 4, 128);
    try std.testing.expectEqual(@as(u8, 128), pixels[3 * 20 + 2]);
    try std.testing.expectEqual(@as(u8, 128), pixels[3 * 20 + 9]);
    try std.testing.expectEqual(@as(u8, 128), pixels[6 * 20 + 2]);
    try std.testing.expectEqual(@as(u8, 255), pixels[4 * 20 + 5]);
    try std.testing.expectEqual(@as(usize, 0), inkCount(pixels));
    // A shrunken rectangle still leaves the interior alone.
    rect(pixels, 20, 10, 2, 3, 1, 1, 128);
    try std.testing.expectEqual(@as(u8, 128), pixels[3 * 20 + 2]);
    try std.testing.expectEqual(@as(u8, 255), pixels[4 * 20 + 3]);
}

test "a turned field keeps every ink pixel" {
    // Turning a glyph moves its pixels, it does not delete them. Mapping each
    // ink dot forward and stamping where it lands leaves holes between the
    // dots, which reads as white speckles; sampling each destination pixel
    // through the inverse turn cannot. So the ink count is about the same at
    // every angle, and that is what this pins.
    const gpa = std.testing.allocator;
    var counts: [5]usize = undefined;
    const angles = [_]i32{ 0, 30, 45, 90, 180 };
    for (angles, 0..) |degrees, i| {
        const gray = try render(gpa, 200, 200, &.{.{ .text = "AB", .x = 70, .y = 80, .size = 40, .rotation = degrees }}, "");
        defer gpa.free(gray.pixels);
        counts[i] = inkCount(gray.pixels);
    }
    const upright = counts[0];
    try std.testing.expect(upright > 0);
    for (counts) |count| {
        const difference = if (count > upright) count - upright else upright - count;
        try std.testing.expect(difference <= upright / 20 + 1);
    }
}

test "a left-aligned line can start left of the label" {
    // The same line, anchored two different ways at the same left edge, draws
    // the same ink: the left-aligned anchor is simply negative.
    const gpa = std.testing.allocator;
    const text = "niimbench";
    const width = blockWidth(sans, text, 16);
    const centred = Field{ .text = text, .x = 10, .y = 2, .size = 16, .align_mode = .center };
    const left = try alignedX(gpa, centred, "");
    try std.testing.expect(left < 0);
    const a = try render(gpa, 60, 24, &.{centred}, "");
    defer gpa.free(a.pixels);
    const b = try render(gpa, 60, 24, &.{.{ .text = text, .x = left, .y = 2, .size = 16, .align_mode = .left }}, "");
    defer gpa.free(b.pixels);
    try std.testing.expect(width > 20);
    try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "a turned centred line turns about its anchor however long it is" {
    // A field turned a quarter turn on a narrow roll: its upright line is far
    // longer than twice its anchor, but turned it fits. It must turn about the
    // anchor, which is where the editor draws its box. Pushing the upright
    // line's left edge back to 0 first moved the ink along the roll and out of
    // the box as soon as the field grew.
    const gpa = std.testing.allocator;
    const width = 48;
    const anchor = 24;
    const text = "niimbench";
    try std.testing.expect(blockWidth(sans, text, 16) > 2 * anchor);
    const gray = try render(gpa, width, 160, &.{.{ .text = text, .x = anchor, .y = 72, .size = 16, .align_mode = .center, .rotation = 90 }}, "");
    defer gpa.free(gray.pixels);
    const first = firstInkColumn(gray.pixels, width, 160).?;
    const last = lastInkColumn(gray.pixels, width, 160).?;
    const middle = (first + last) / 2;
    try std.testing.expect(middle + 3 >= anchor and middle <= anchor + 3);
}

test "a half turn puts the top of the text at the bottom" {
    const gpa = std.testing.allocator;
    // `T` has its bar on top. Turned 180 degrees about the block's centre, the
    // bar is on the bottom row of the block instead.
    const upright = try render(gpa, 40, 40, &.{.{ .text = "T", .x = 10, .y = 10, .size = 20 }}, "");
    defer gpa.free(upright.pixels);
    const turned = try render(gpa, 40, 40, &.{.{ .text = "T", .x = 10, .y = 10, .size = 20, .rotation = 180 }}, "");
    defer gpa.free(turned.pixels);
    const bar = struct {
        fn row(pixels: []const u8) usize {
            var best: usize = 0;
            var best_ink: usize = 0;
            for (0..40) |y| {
                const ink = inkCount(pixels[y * 40 ..][0..40]);
                if (ink > best_ink) {
                    best_ink = ink;
                    best = y;
                }
            }
            return best;
        }
    }.row;
    try std.testing.expect(bar(upright.pixels) < 20);
    try std.testing.expect(bar(turned.pixels) >= 20);
}

/// The face the tests measure with: the one a field gets when it names none.
const sans = font.find(font.default_id).?;

test "a field is drawn in the font it names" {
    const gpa = std.testing.allocator;
    const default = try render(gpa, 200, 30, &.{.{ .text = "Label 42", .x = 2, .y = 2, .size = 20 }}, "");
    defer gpa.free(default.pixels);
    const named = try render(gpa, 200, 30, &.{.{ .text = "Label 42", .x = 2, .y = 2, .size = 20, .font = font.default_id }}, "");
    defer gpa.free(named.pixels);
    try std.testing.expectEqualSlices(u8, default.pixels, named.pixels);
    // Every other font draws the same text differently, and the block it
    // reports is the one it draws in.
    for (font.fonts[1..]) |other| {
        const drawn = try render(gpa, 200, 30, &.{.{ .text = "Label 42", .x = 2, .y = 2, .size = 20, .font = other.id }}, "");
        defer gpa.free(drawn.pixels);
        try std.testing.expect(!std.mem.eql(u8, default.pixels, drawn.pixels));
        const face = try faceOf(.{ .font = other.id });
        try std.testing.expect(lastInkColumn(drawn.pixels, 200, 30).? < 2 + blockWidth(face, "Label 42", 20) + 2);
    }
}

test "a font this build does not carry is an error, not a fallback" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnknownFont, render(gpa, 40, 20, &.{.{ .text = "A", .font = "comic-sans" }}, ""));
    try std.testing.expectError(error.UnknownFont, alignedX(gpa, .{ .text = "A", .font = "comic-sans" }, ""));
}

/// A letter drawn alone and centred on a label of its own, turned by
/// `degrees`, as ink pieces and holes.
fn turnedTopology(gpa: std.mem.Allocator, id: []const u8, letter: []const u8, size: usize, degrees: i32) !font.Topology {
    const face = try faceOf(.{ .font = id });
    const bw = blockWidth(face, letter, size);
    // Room for the block turned any way, and no more: its diagonal is under
    // twice its longer side, and every pixel here is one the test walks.
    const side = 2 * @max(bw, size) + 8;
    const field = Field{ .text = letter, .x = @intCast((side - bw) / 2), .y = (side - size) / 2, .size = size, .rotation = degrees, .font = id };
    const gray = try render(gpa, side, side, &.{field}, "");
    defer gpa.free(gray.pixels);
    for (gray.pixels) |*pixel| pixel.* = @intFromBool(pixel.* == 0);
    return font.topology(gpa, gray.pixels, side, side);
}

test "turned letters keep their strokes and counters, in every font" {
    // A letter at any angle has no more pieces and no more holes than the same
    // letter drawn huge and upright, the rule `font.zig` holds upright letters
    // to (100 dots is as huge as that needs, and a quarter of the walk of
    // 200). Filling a letter upright and then turning its dots put every stroke
    // on the dots twice, and at most angles a thin stroke came out stepped and
    // broken: `niimbench` at 70 degrees was a scatter of pieces.
    const gpa = std.testing.allocator;
    const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const angles = [_]i32{ 10, 25, 40, 55, 70, 110, 160, 290 };
    const sizes = [_]usize{ 16, 20, 24 };
    var failures: usize = 0;
    for (font.fonts) |each| {
        for (0..letters.len) |i| {
            const letter = letters[i .. i + 1];
            const want = try turnedTopology(gpa, each.id, letter, 100, 0);
            for (sizes) |size| {
                for (angles) |degrees| {
                    const got = try turnedTopology(gpa, each.id, letter, size, degrees);
                    if (got.pieces <= want.pieces and got.holes <= want.holes) continue;
                    failures += 1;
                    if (failures <= 20) std.debug.print("  {s} {s} at {d} turned {d}: {d} pieces {d} holes, want {d} and {d}\n", .{ each.id, letter, size, degrees, got.pieces, got.holes, want.pieces, want.holes });
                }
            }
        }
    }
    if (failures > 0) std.debug.print("  {d} broken\n", .{failures});
    try std.testing.expectEqual(@as(usize, 0), failures);
}
