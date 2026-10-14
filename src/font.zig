const std = @import("std");

/// The typefaces a field can be drawn in, embedded so a print never depends on
/// what is installed. Every one is free to use and redistribute; each family's
/// licence sits next to its files, and `fonts/README.md` lists them.
///
/// This is a TrueType reader and rasteriser, just enough of one: `cmap` format
/// 4 for the character map, `glyf` outlines (simple and composite), `hmtx`
/// advances. No hinting and no kerning — the editor measures text from the same
/// advance tables (`/api/label/metrics`), and kerning would be a second table it
/// had to agree with.
pub const Font = struct {
    /// What a field names in its `font`, and what a saved layout stores.
    id: []const u8,
    /// What the editor shows.
    name: []const u8,
    face: Face,
};

pub const fonts = [_]Font{
    embed("dejavu-sans", "DejaVu Sans", "DejaVuSans.ttf"),
    embed("dejavu-sans-bold", "DejaVu Sans Bold", "DejaVuSans-Bold.ttf"),
    embed("dejavu-sans-mono", "DejaVu Sans Mono", "DejaVuSansMono.ttf"),
    embed("dejavu-serif", "DejaVu Serif", "DejaVuSerif.ttf"),
    embed("liberation-sans", "Liberation Sans", "LiberationSans-Regular.ttf"),
    embed("liberation-sans-bold", "Liberation Sans Bold", "LiberationSans-Bold.ttf"),
    embed("liberation-serif", "Liberation Serif", "LiberationSerif-Regular.ttf"),
    embed("liberation-mono", "Liberation Mono", "LiberationMono-Regular.ttf"),
    embed("open-sans", "Open Sans", "OpenSans-Regular.ttf"),
    embed("open-sans-bold", "Open Sans Bold", "OpenSans-Bold.ttf"),
    embed("fira-sans", "Fira Sans", "FiraSans-Book.ttf"),
    embed("fira-sans-bold", "Fira Sans Bold", "FiraSans-Bold.ttf"),
    embed("noto-sans", "Noto Sans", "NotoSans-Regular.ttf"),
    embed("noto-serif", "Noto Serif", "NotoSerif-Regular.ttf"),
    embed("hack", "Hack", "Hack-Regular.ttf"),
};

/// The font a field is drawn in when it names none.
pub const default_id = "dejavu-sans";

fn embed(comptime id: []const u8, comptime name: []const u8, comptime file: []const u8) Font {
    @setEvalBranchQuota(100_000);
    return .{
        .id = id,
        .name = name,
        .face = Face.parse(@embedFile("fonts/" ++ file)) catch @compileError("not a TrueType font this reader handles: fonts/" ++ file),
    };
}

/// The face a font id names, or null for an id this build does not carry.
pub fn find(id: []const u8) ?*const Face {
    for (&fonts) |*font| {
        if (std.mem.eql(u8, font.id, id)) return &font.face;
    }
    return null;
}

pub const Face = struct {
    data: []const u8,
    units_per_em: u16,
    ascent: i32,
    descent: i32,
    num_glyphs: u16,
    num_hmetrics: u16,
    loca_long: bool,
    cmap: usize,
    loca: usize,
    glyf: usize,
    hmtx: usize,

    pub fn parse(data: []const u8) !Face {
        const tables = u16At(data, 4);
        var head: ?usize = null;
        var hhea: ?usize = null;
        var maxp: ?usize = null;
        var cmap: ?usize = null;
        var loca: ?usize = null;
        var glyf: ?usize = null;
        var hmtx: ?usize = null;
        for (0..tables) |i| {
            const record = 12 + i * 16;
            const tag = data[record..][0..4];
            const offset: usize = u32At(data, record + 8);
            if (std.mem.eql(u8, tag, "head")) head = offset;
            if (std.mem.eql(u8, tag, "hhea")) hhea = offset;
            if (std.mem.eql(u8, tag, "maxp")) maxp = offset;
            if (std.mem.eql(u8, tag, "cmap")) cmap = offset;
            if (std.mem.eql(u8, tag, "loca")) loca = offset;
            if (std.mem.eql(u8, tag, "glyf")) glyf = offset;
            if (std.mem.eql(u8, tag, "hmtx")) hmtx = offset;
        }
        const head_at = head orelse return error.BadFont;
        const hhea_at = hhea orelse return error.BadFont;
        return .{
            .data = data,
            .units_per_em = u16At(data, head_at + 18),
            .loca_long = i16At(data, head_at + 50) != 0,
            .ascent = i16At(data, hhea_at + 4),
            .descent = i16At(data, hhea_at + 6),
            .num_hmetrics = u16At(data, hhea_at + 34),
            .num_glyphs = u16At(data, (maxp orelse return error.BadFont) + 4),
            .cmap = try unicodeMap(data, cmap orelse return error.BadFont),
            .loca = loca orelse return error.BadFont,
            .glyf = glyf orelse return error.BadFont,
            .hmtx = hmtx orelse return error.BadFont,
        };
    }

    /// Font units from the top of a line to its bottom. A field's `size` is
    /// this many dots, so a line of text is exactly `size` dots tall.
    pub fn lineUnits(self: Face) u32 {
        return @intCast(self.ascent - self.descent);
    }

    /// The glyph for a code point, or 0 (the font's missing-glyph box).
    pub fn glyphIndex(self: Face, codepoint: u21) u16 {
        if (codepoint > 0xFFFF) return 0;
        const cp: u16 = @intCast(codepoint);
        const at = self.cmap;
        const segments = u16At(self.data, at + 6) / 2;
        const ends = at + 14;
        const starts = ends + segments * 2 + 2;
        const deltas = starts + segments * 2;
        const ranges = deltas + segments * 2;
        for (0..segments) |i| {
            if (u16At(self.data, ends + i * 2) < cp) continue;
            const start = u16At(self.data, starts + i * 2);
            if (start > cp) return 0;
            const delta = u16At(self.data, deltas + i * 2);
            const range = u16At(self.data, ranges + i * 2);
            if (range == 0) return cp +% delta;
            const slot = ranges + i * 2 + @as(usize, range) + @as(usize, cp - start) * 2;
            const glyph = u16At(self.data, slot);
            return if (glyph == 0) 0 else glyph +% delta;
        }
        return 0;
    }

    pub fn advance(self: Face, glyph: u16) u32 {
        const index = @min(glyph, self.num_hmetrics - 1);
        return u16At(self.data, self.hmtx + @as(usize, index) * 4);
    }

    /// Every code point the font maps, with its advance, in order. The editor
    /// gets this table so it can measure a line the way `lineWidth` does.
    pub fn eachMapped(self: Face, context: anytype, comptime visit: fn (@TypeOf(context), u21, u32) anyerror!void) !void {
        const at = self.cmap;
        const segments = u16At(self.data, at + 6) / 2;
        const ends = at + 14;
        const starts = ends + segments * 2 + 2;
        for (0..segments) |i| {
            const start = u16At(self.data, starts + i * 2);
            const end = u16At(self.data, ends + i * 2);
            if (start == 0xFFFF) continue;
            var cp: u32 = start;
            while (cp <= end) : (cp += 1) {
                const glyph = self.glyphIndex(@intCast(cp));
                if (glyph != 0) try visit(context, @intCast(cp), self.advance(glyph));
            }
        }
    }

    fn glyphData(self: Face, glyph: u16) ?[]const u8 {
        if (glyph >= self.num_glyphs) return null;
        const start: usize, const end: usize = if (self.loca_long)
            .{ u32At(self.data, self.loca + @as(usize, glyph) * 4), u32At(self.data, self.loca + @as(usize, glyph) * 4 + 4) }
        else
            .{ @as(usize, u16At(self.data, self.loca + @as(usize, glyph) * 2)) * 2, @as(usize, u16At(self.data, self.loca + @as(usize, glyph) * 2 + 2)) * 2 };
        if (end <= start) return null;
        return self.data[self.glyf + start .. self.glyf + end];
    }
};

/// Advance units of one line in `face`, summed over its code points. `text` is
/// UTF-8; a byte that is not part of valid UTF-8 counts as the code point it
/// spells.
pub fn textUnits(face: *const Face, text: []const u8) u64 {
    var units: u64 = 0;
    var it = Codepoints{ .text = text };
    while (it.next()) |cp| units += face.advance(face.glyphIndex(cp));
    return units;
}

/// Width in dots of one line at `size`, rounded up to a whole dot. The editor
/// computes the same integer from the same table: `ceil(units * size / line)`.
pub fn lineWidth(face: *const Face, text: []const u8, size: usize) usize {
    const line: u64 = face.lineUnits();
    return @intCast((textUnits(face, text) * size + line - 1) / line);
}

const Codepoints = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Codepoints) ?u21 {
        if (self.at >= self.text.len) return null;
        const first = self.text[self.at];
        const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
        if (self.at + len <= self.text.len) {
            if (std.unicode.utf8Decode(self.text[self.at..][0..len])) |cp| {
                self.at += len;
                return cp;
            } else |_| {}
        }
        self.at += 1;
        return first;
    }
};

/// A turn about a point in grid dots, clockwise with y down: what a field's
/// rotation does to its block. The default turns nothing, exactly.
pub const Turn = struct {
    cx: f32 = 0,
    cy: f32 = 0,
    cos: f32 = 1,
    sin: f32 = 0,

    fn apply(self: Turn, p: [2]f32) [2]f32 {
        const dx = p[0] - self.cx;
        const dy = p[1] - self.cy;
        return .{ self.cx + dx * self.cos - dy * self.sin, self.cy + dx * self.sin + dy * self.cos };
    }
};

/// One line in `face` drawn into `grid` (one byte per dot, `stride` wide), with
/// the line's top-left at (`left`, `top`) in grid dots before `turn`. Inked
/// dots are set to 1; `fill` says which dots those are. The outline is turned
/// before it is filled, so a turned stroke is put on the dots once, and the
/// dropout rule keeps it unbroken at any angle.
pub fn drawLine(gpa: std.mem.Allocator, face: *const Face, grid: []u8, stride: usize, left: f32, top: f32, size: usize, text: []const u8, turn: Turn) !void {
    var edges: Edges = .{ .gpa = gpa, .face = face, .turn = turn };
    defer edges.deinit();
    const k = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(face.lineUnits()));
    const baseline = top + @as(f32, @floatFromInt(face.ascent)) * k;
    var pen: f32 = left;
    var it = Codepoints{ .text = text };
    while (it.next()) |cp| {
        const glyph = face.glyphIndex(cp);
        edges.list.clearRetainingCapacity();
        edges.areas.clearRetainingCapacity();
        edges.origin = .{ pen, baseline };
        edges.k = k;
        try outline(&edges, glyph, identity, 0);
        try drawGlyph(gpa, grid, stride, edges.list.items, counters(edges.areas.items));
        pen += @as(f32, @floatFromInt(face.advance(glyph))) * k;
    }
}

/// One glyph, filled in a window of its own and then laid onto `grid`, so
/// its holes can be counted against its outline before it meets its
/// neighbours.
fn drawGlyph(gpa: std.mem.Allocator, grid: []u8, stride: usize, edges: []const Edge, holes: usize) !void {
    if (edges.len == 0 or stride == 0) return;
    const rows = grid.len / stride;
    var lo = [2]f32{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi = [2]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (edges) |e| {
        lo = .{ @min(lo[0], @min(e.x0, e.x1)), @min(lo[1], @min(e.y0, e.y1)) };
        hi = .{ @max(hi[0], @max(e.x0, e.x1)), @max(hi[1], @max(e.y0, e.y1)) };
    }
    // One white dot of border all round, so white outside the glyph touches
    // the window's edge and is never mistaken for a hole.
    const x0: isize = @as(isize, @intFromFloat(@floor(lo[0]))) - 1;
    const y0: isize = @as(isize, @intFromFloat(@floor(lo[1]))) - 1;
    const w: usize = @intCast(@as(isize, @intFromFloat(@floor(hi[0]))) + 2 - x0);
    const h: usize = @intCast(@as(isize, @intFromFloat(@floor(hi[1]))) + 2 - y0);
    const local = try gpa.alloc(u8, w * h);
    defer gpa.free(local);
    @memset(local, 0);
    const moved = try gpa.alloc(Edge, edges.len);
    defer gpa.free(moved);
    const dx: f32 = @floatFromInt(x0);
    const dy: f32 = @floatFromInt(y0);
    for (edges, moved) |e, *m| m.* = .{ .x0 = e.x0 - dx, .y0 = e.y0 - dy, .x1 = e.x1 - dx, .y1 = e.y1 - dy };
    try fill(gpa, local, w, moved);
    try closeSpecks(gpa, local, w, h, holes);
    for (0..h) |ly| {
        const gy = y0 + @as(isize, @intCast(ly));
        if (gy < 0 or gy >= rows) continue;
        for (0..w) |lx| {
            const gx = x0 + @as(isize, @intCast(lx));
            if (gx < 0 or gx >= stride or local[ly * w + lx] == 0) continue;
            grid[@as(usize, @intCast(gy)) * stride + @as(usize, @intCast(gx))] = 1;
        }
    }
}

/// How many counters an outline has: the contours wound the other way from
/// its largest one. An `o` has one, a `B` two, an `i` none.
fn counters(areas: []const f32) usize {
    var largest: f32 = 0;
    for (areas) |a| {
        if (@abs(a) > @abs(largest)) largest = a;
    }
    var count: usize = 0;
    for (areas) |a| {
        if ((a > 0) != (largest > 0)) count += 1;
    }
    return count;
}

/// Fill the smallest enclosed white regions until no more are left than the
/// outline has counters. Where a counter narrows to a point, a dot centre can
/// land in the point and come out as a white speck cut off from the rest of
/// the counter; that speck is not a hole the letter has.
fn closeSpecks(gpa: std.mem.Allocator, grid: []u8, w: usize, h: usize, holes: usize) !void {
    const region = try gpa.alloc(u32, w * h);
    defer gpa.free(region);
    @memset(region, 0);
    var sizes: std.ArrayList(Hole) = .empty;
    defer sizes.deinit(gpa);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    var next: u32 = 1;
    for (0..w * h) |start| {
        if (grid[start] != 0 or region[start] != 0) continue;
        // Region ids start at 1; 0 is unvisited.
        var area: usize = 0;
        var outside = false;
        stack.clearRetainingCapacity();
        try stack.append(gpa, start);
        region[start] = next;
        while (stack.pop()) |i| {
            area += 1;
            const x = i % w;
            const y = i / w;
            if (x == 0 or y == 0 or x == w - 1 or y == h - 1) outside = true;
            const around = [4]?usize{
                if (x > 0) i - 1 else null,
                if (x + 1 < w) i + 1 else null,
                if (y > 0) i - w else null,
                if (y + 1 < h) i + w else null,
            };
            for (around) |maybe| {
                const n = maybe orelse continue;
                if (grid[n] != 0 or region[n] != 0) continue;
                region[n] = next;
                try stack.append(gpa, n);
            }
        }
        if (!outside) try sizes.append(gpa, .{ .id = next, .area = area });
        next += 1;
    }
    if (sizes.items.len <= holes) return;
    std.mem.sort(Hole, sizes.items, {}, Hole.smaller);
    for (sizes.items[0 .. sizes.items.len - holes]) |speck| {
        for (region, 0..) |id, i| {
            if (id == speck.id) grid[i] = 1;
        }
    }
}

const Hole = struct {
    id: u32,
    area: usize,

    fn smaller(_: void, a: Hole, b: Hole) bool {
        return a.area < b.area;
    }
};

/// One straight piece of an outline, from (x0, y0) to (x1, y1) as it was drawn:
/// the direction is what the non-zero rule counts.
const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

const Edges = struct {
    gpa: std.mem.Allocator,
    face: *const Face,
    list: std.ArrayList(Edge) = .empty,
    /// Signed area of each contour, in dots: the sign is its winding.
    areas: std.ArrayList(f32) = .empty,
    origin: [2]f32 = .{ 0, 0 },
    k: f32 = 1,
    turn: Turn = .{},

    fn deinit(self: *Edges) void {
        self.list.deinit(self.gpa);
        self.areas.deinit(self.gpa);
    }

    /// Font units to grid dots: y grows down on the label and up in the font.
    fn dot(self: *const Edges, p: [2]f32) [2]f32 {
        return self.turn.apply(.{ self.origin[0] + p[0] * self.k, self.origin[1] - p[1] * self.k });
    }

    fn line(self: *Edges, a: [2]f32, b: [2]f32) !void {
        const p = self.dot(a);
        const q = self.dot(b);
        if (p[0] == q[0] and p[1] == q[1]) return;
        try self.list.append(self.gpa, .{ .x0 = p[0], .y0 = p[1], .x1 = q[0], .y1 = q[1] });
    }

    /// A quadratic curve as straight pieces about two dots long.
    fn curve(self: *Edges, a: [2]f32, c: [2]f32, b: [2]f32) !void {
        const length = (dist(a, c) + dist(c, b)) * self.k;
        const pieces: usize = @intFromFloat(std.math.clamp(@ceil(length / 2), 1, 32));
        var from = a;
        for (1..pieces + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(pieces));
            const u = 1 - t;
            const to = [2]f32{
                u * u * a[0] + 2 * u * t * c[0] + t * t * b[0],
                u * u * a[1] + 2 * u * t * c[1] + t * t * b[1],
            };
            try self.line(from, to);
            from = to;
        }
    }
};

fn dist(a: [2]f32, b: [2]f32) f32 {
    return @sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
}

/// A composite glyph's placement of one part: x' = a x + c y + e, y' = b x + d y + f.
const Affine = [6]f32;
const identity: Affine = .{ 1, 0, 0, 1, 0, 0 };

fn apply(m: Affine, x: f32, y: f32) [2]f32 {
    return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
}

fn outline(edges: *Edges, glyph: u16, m: Affine, depth: u8) !void {
    const data = edges.face.glyphData(glyph) orelse return;
    const contours = i16At(data, 0);
    if (contours >= 0) return simple(edges, data, @intCast(contours), m);
    if (depth > 4) return;
    // Composite: parts placed by offset and an optional scale or 2x2 matrix.
    var at: usize = 10;
    while (true) {
        const flags = u16At(data, at);
        const part = u16At(data, at + 2);
        at += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & 0x1 != 0) {
            if (flags & 0x2 != 0) {
                dx = @floatFromInt(i16At(data, at));
                dy = @floatFromInt(i16At(data, at + 2));
            }
            at += 4;
        } else {
            if (flags & 0x2 != 0) {
                dx = @floatFromInt(@as(i8, @bitCast(data[at])));
                dy = @floatFromInt(@as(i8, @bitCast(data[at + 1])));
            }
            at += 2;
        }
        var part_m: Affine = .{ 1, 0, 0, 1, dx, dy };
        if (flags & 0x8 != 0) {
            const s = f2dot14(data, at);
            part_m[0] = s;
            part_m[3] = s;
            at += 2;
        } else if (flags & 0x40 != 0) {
            part_m[0] = f2dot14(data, at);
            part_m[3] = f2dot14(data, at + 2);
            at += 4;
        } else if (flags & 0x80 != 0) {
            part_m[0] = f2dot14(data, at);
            part_m[1] = f2dot14(data, at + 2);
            part_m[2] = f2dot14(data, at + 4);
            part_m[3] = f2dot14(data, at + 6);
            at += 8;
        }
        // Compose: the part's own placement first, then the parent's.
        const combined: Affine = .{
            m[0] * part_m[0] + m[2] * part_m[1],
            m[1] * part_m[0] + m[3] * part_m[1],
            m[0] * part_m[2] + m[2] * part_m[3],
            m[1] * part_m[2] + m[3] * part_m[3],
            m[0] * part_m[4] + m[2] * part_m[5] + m[4],
            m[1] * part_m[4] + m[3] * part_m[5] + m[5],
        };
        try outline(edges, part, combined, depth + 1);
        if (flags & 0x20 == 0) break;
    }
}

fn simple(edges: *Edges, data: []const u8, contours: usize, m: Affine) !void {
    if (contours == 0) return;
    const points: usize = @as(usize, u16At(data, 10 + (contours - 1) * 2)) + 1;
    var at = 10 + contours * 2;
    at += 2 + u16At(data, at);

    var flags_buf: [1024]u8 = undefined;
    var xs: [1024]f32 = undefined;
    var ys: [1024]f32 = undefined;
    if (points > flags_buf.len) return;

    var i: usize = 0;
    while (i < points) {
        const flag = data[at];
        at += 1;
        flags_buf[i] = flag;
        i += 1;
        if (flag & 0x8 != 0) {
            var repeat = data[at];
            at += 1;
            while (repeat > 0 and i < points) : (repeat -= 1) {
                flags_buf[i] = flag;
                i += 1;
            }
        }
    }
    var x: i32 = 0;
    for (0..points) |p| {
        const flag = flags_buf[p];
        if (flag & 0x2 != 0) {
            const d: i32 = data[at];
            at += 1;
            x += if (flag & 0x10 != 0) d else -d;
        } else if (flag & 0x10 == 0) {
            x += i16At(data, at);
            at += 2;
        }
        xs[p] = @floatFromInt(x);
    }
    var y: i32 = 0;
    for (0..points) |p| {
        const flag = flags_buf[p];
        if (flag & 0x4 != 0) {
            const d: i32 = data[at];
            at += 1;
            y += if (flag & 0x20 != 0) d else -d;
        } else if (flag & 0x20 == 0) {
            y += i16At(data, at);
            at += 2;
        }
        ys[p] = @floatFromInt(y);
    }

    var first: usize = 0;
    for (0..contours) |c| {
        const last: usize = u16At(data, 10 + c * 2);
        if (last < first or last >= points) return;
        try contour(edges, flags_buf[first .. last + 1], xs[first .. last + 1], ys[first .. last + 1], m);
        first = last + 1;
    }
}

/// One closed contour of on-curve and off-curve points. Two off-curve points
/// in a row imply an on-curve point halfway between them.
fn contour(edges: *Edges, flags: []const u8, xs: []const f32, ys: []const f32, m: Affine) !void {
    const n = flags.len;
    if (n < 2) return;
    const first = edges.list.items.len;
    // Start on an on-curve point — the first, else the last — or, when both
    // are off-curve, on the point implied between them.
    var begin: usize = 0;
    var count: usize = n;
    var start: [2]f32 = undefined;
    if (flags[0] & 0x1 != 0) {
        start = apply(m, xs[0], ys[0]);
        begin = 1;
        count = n - 1;
    } else if (flags[n - 1] & 0x1 != 0) {
        start = apply(m, xs[n - 1], ys[n - 1]);
        count = n - 1;
    } else {
        start = apply(m, (xs[0] + xs[n - 1]) / 2, (ys[0] + ys[n - 1]) / 2);
    }
    var current = start;
    var control: ?[2]f32 = null;
    for (begin..begin + count) |i| {
        const p = apply(m, xs[i], ys[i]);
        if (flags[i] & 0x1 != 0) {
            if (control) |c| try edges.curve(current, c, p) else try edges.line(current, p);
            current = p;
            control = null;
        } else {
            if (control) |c| {
                const mid = [2]f32{ (c[0] + p[0]) / 2, (c[1] + p[1]) / 2 };
                try edges.curve(current, c, mid);
                current = mid;
            }
            control = p;
        }
    }
    if (control) |c| try edges.curve(current, c, start) else try edges.line(current, start);
    var area: f32 = 0;
    for (edges.list.items[first..]) |e| area += e.x0 * e.y1 - e.x1 * e.y0;
    if (area != 0) try edges.areas.append(edges.gpa, area);
}

/// Fill the edges into `grid` with the non-zero rule, the way a TrueType
/// rasteriser does without hinting: a dot is inked when its centre is inside
/// a glyph, and a stroke too thin to cover any dot centre — it falls between
/// two of them — inks the dot it passes through instead (dropout control).
/// That is checked across each row and down each column, so a thin stroke of
/// either direction stays unbroken.
///
/// Inking a dot by the share of it a glyph covers broke exactly those strokes:
/// a lower-case stem a dot and a half wide that straddles two dots covers
/// neither by half, and the letter came out with white gaps in it.
fn fill(gpa: std.mem.Allocator, grid: []u8, stride: usize, edges: []const Edge) !void {
    if (edges.len == 0 or stride == 0) return;
    const rows = grid.len / stride;
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(gpa);
    var box = [4]f32{ std.math.floatMax(f32), std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (edges) |e| {
        box[0] = @min(box[0], @min(e.x0, e.x1));
        box[1] = @min(box[1], @min(e.y0, e.y1));
        box[2] = @max(box[2], @max(e.x0, e.x1));
        box[3] = @max(box[3], @max(e.y0, e.y1));
    }
    const row_range = span(box[1], box[3], rows);
    for (row_range.start..row_range.end) |row| {
        try crossings(gpa, &hits, edges, .across, @as(f32, @floatFromInt(row)) + 0.5);
        inked(hits.items, grid[row * stride ..][0..stride], 1, true);
    }
    const col_range = span(box[0], box[2], stride);
    for (col_range.start..col_range.end) |col| {
        try crossings(gpa, &hits, edges, .down, @as(f32, @floatFromInt(col)) + 0.5);
        inked(hits.items, grid[col..], stride, false);
    }
}

/// Where the outline crosses one scan line — a row at height `at` when
/// `across`, a column at `at` when `down` — with the direction of each
/// crossing. An edge that runs along the scan line does not cross it.
fn crossings(gpa: std.mem.Allocator, hits: *std.ArrayList(Hit), edges: []const Edge, line: enum { across, down }, at: f32) !void {
    hits.clearRetainingCapacity();
    for (edges) |e| {
        const from = if (line == .across) e.y0 else e.x0;
        const to = if (line == .across) e.y1 else e.x1;
        if (from == to) continue;
        if (at < @min(from, to) or at >= @max(from, to)) continue;
        const t = (at - from) / (to - from);
        const along = if (line == .across) e.x0 + t * (e.x1 - e.x0) else e.y0 + t * (e.y1 - e.y0);
        try hits.append(gpa, .{ .at = along, .winding = if (to > from) 1 else -1 });
    }
}

/// The dots of one row (`step` 1) or one column (`step` = the row stride)
/// that lie inside, given where the outline crosses it. `centres` inks every
/// dot whose centre is inside; either way a span that holds no centre inks
/// the dot under its middle.
fn inked(hits: []Hit, line: []u8, step: usize, centres: bool) void {
    std.mem.sort(Hit, hits, {}, Hit.before);
    const count = (line.len + step - 1) / step;
    var winding: i32 = 0;
    for (hits, 0..) |hit, h| {
        if (winding != 0 and h > 0) {
            const a = hits[h - 1].at;
            const b = hit.at;
            const first = @ceil(a - 0.5);
            const end = @ceil(b - 0.5);
            if (end > first) {
                if (centres) {
                    const dots = span(first, end - 1, count);
                    for (dots.start..dots.end) |i| line[i * step] = 1;
                }
            } else {
                const middle = @floor((a + b) / 2);
                if (middle >= 0 and middle < @as(f32, @floatFromInt(count))) line[@as(usize, @intFromFloat(middle)) * step] = 1;
            }
        }
        winding += hit.winding;
    }
}

const Hit = struct {
    at: f32,
    winding: i8,

    fn before(_: void, a: Hit, b: Hit) bool {
        return a.at < b.at;
    }
};

/// Whole indices from `from` to `to`, both rounded outward, kept inside
/// `0..limit`.
fn span(from: f32, to: f32, limit: usize) Range {
    const top: f32 = @floatFromInt(limit);
    return .{
        .start = @intFromFloat(std.math.clamp(@floor(from), 0, top)),
        .end = @intFromFloat(std.math.clamp(@floor(to) + 1, 0, top)),
    };
}

const Range = struct {
    start: usize,
    end: usize,
};
fn unicodeMap(data: []const u8, cmap: usize) !usize {
    const count = u16At(data, cmap + 2);
    for (0..count) |i| {
        const record = cmap + 4 + i * 8;
        const platform = u16At(data, record);
        const encoding = u16At(data, record + 2);
        const at = cmap + u32At(data, record + 4);
        const unicode = platform == 0 or (platform == 3 and encoding == 1);
        if (unicode and u16At(data, at) == 4) return at;
    }
    return error.BadFont;
}

fn f2dot14(data: []const u8, at: usize) f32 {
    return @as(f32, @floatFromInt(i16At(data, at))) / 16384.0;
}

fn u16At(data: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, data[at..][0..2], .big);
}

fn i16At(data: []const u8, at: usize) i16 {
    return std.mem.readInt(i16, data[at..][0..2], .big);
}

fn u32At(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .big);
}

test "every font maps text, measures it, and has a unique id" {
    for (&fonts, 0..) |*font, i| {
        const face = &font.face;
        try std.testing.expect(face.units_per_em > 0);
        try std.testing.expect(face.ascent > 0 and face.descent < 0);
        try std.testing.expect(face.glyphIndex('A') != 0);
        try std.testing.expect(face.glyphIndex(0xE9) != 0);
        try std.testing.expectEqual(@as(u16, 0), face.glyphIndex(0x1F600));
        // Width grows with size, and an empty line has none.
        try std.testing.expect(lineWidth(face, "Hello", 32) > lineWidth(face, "Hello", 16));
        try std.testing.expectEqual(@as(usize, 0), lineWidth(face, "", 16));
        try std.testing.expectEqual(face, find(font.id).?);
        for (fonts[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, font.id, other.id));
    }
    try std.testing.expect(find(default_id) != null);
    try std.testing.expectEqual(@as(?*const Face, null), find("comic-sans"));
}

test "a proportional font and a monospaced one measure differently" {
    const sans = find("dejavu-sans").?;
    const mono = find("dejavu-sans-mono").?;
    // In a proportional face an M is wider than an i; in a monospaced one they
    // are the same width.
    try std.testing.expect(lineWidth(sans, "M", 40) > lineWidth(sans, "i", 40));
    try std.testing.expectEqual(lineWidth(mono, "M", 40), lineWidth(mono, "i", 40));
}

test "a drawn line has ink inside its measured box" {
    const gpa = std.testing.allocator;
    const size = 32;
    const text = "Hello";
    for (fonts) |font| {
        const face = &font.face;
        const w = lineWidth(face, text, size) + 8;
        const h = size + 8;
        const grid = try gpa.alloc(u8, w * h);
        defer gpa.free(grid);
        @memset(grid, 0);
        try drawLine(gpa, face, grid, w, 4, 4, size, text, .{});
        var ink: usize = 0;
        var first_row: usize = h;
        var last_row: usize = 0;
        for (0..h) |row| {
            for (0..w) |col| {
                if (grid[row * w + col] == 0) continue;
                ink += 1;
                first_row = @min(first_row, row);
                last_row = @max(last_row, row);
            }
        }
        try std.testing.expect(ink > 100);
        // Capitals reach well above the middle of the line and stop above its
        // bottom, which is where the descenders go.
        try std.testing.expect(first_row >= 4 and first_row < 4 + size / 2);
        try std.testing.expect(last_row < 4 + size);
    }
}

test "an accented letter draws its accent" {
    // `é` is a composite glyph in most fonts: the `e` and the accent are two
    // parts placed by offset.
    const gpa = std.testing.allocator;
    const size = 40;
    const w = 60;
    for (fonts) |font| {
        const plain = try gpa.alloc(u8, w * w);
        defer gpa.free(plain);
        const accented = try gpa.alloc(u8, w * w);
        defer gpa.free(accented);
        @memset(plain, 0);
        @memset(accented, 0);
        try drawLine(gpa, &font.face, plain, w, 2, 2, size, "e", .{});
        try drawLine(gpa, &font.face, accented, w, 2, 2, size, "\u{e9}", .{});
        var plain_ink: usize = 0;
        var accented_ink: usize = 0;
        for (plain, accented) |a, b| {
            plain_ink += a;
            accented_ink += b;
        }
        try std.testing.expect(accented_ink > plain_ink);
    }
}

/// Ink pieces (8-connected) and enclosed white holes (4-connected white that
/// does not reach the edge) of a `w` × `h` grid. A broken stroke is an extra
/// piece; a white speck inside a letter is an extra hole.
pub const Topology = struct { pieces: usize, holes: usize };

pub fn topology(gpa: std.mem.Allocator, grid: []const u8, w: usize, h: usize) !Topology {
    const seen = try gpa.alloc(u8, w * h);
    defer gpa.free(seen);
    @memset(seen, 0);
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(gpa);
    var result = Topology{ .pieces = 0, .holes = 0 };
    // White reachable from the edge is outside, not a hole.
    for (0..w * h) |i| {
        const x = i % w;
        const y = i / w;
        if (x != 0 and y != 0 and x != w - 1 and y != h - 1) continue;
        if (grid[i] != 0 or seen[i] != 0) continue;
        try flood(gpa, &stack, grid, seen, w, h, i, 0, false);
    }
    for (0..w * h) |i| {
        if (seen[i] != 0) continue;
        if (grid[i] != 0) {
            result.pieces += 1;
            try flood(gpa, &stack, grid, seen, w, h, i, 1, true);
        } else {
            result.holes += 1;
            try flood(gpa, &stack, grid, seen, w, h, i, 0, false);
        }
    }
    return result;
}

fn flood(gpa: std.mem.Allocator, stack: *std.ArrayList(usize), grid: []const u8, seen: []u8, w: usize, h: usize, start: usize, value: u8, diagonal: bool) !void {
    stack.clearRetainingCapacity();
    try stack.append(gpa, start);
    seen[start] = 1;
    while (stack.pop()) |i| {
        const x: isize = @intCast(i % w);
        const y: isize = @intCast(i / w);
        var dy: isize = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                if (!diagonal and dx != 0 and dy != 0) continue;
                const nx = x + dx;
                const ny = y + dy;
                if (nx < 0 or ny < 0 or nx >= w or ny >= h) continue;
                const n: usize = @intCast(ny * @as(isize, @intCast(w)) + nx);
                if (seen[n] != 0 or (grid[n] != 0) != (value != 0)) continue;
                seen[n] = 1;
                try stack.append(gpa, n);
            }
        }
    }
}

fn glyphTopology(gpa: std.mem.Allocator, face: *const Face, text: []const u8, size: usize, phase: f32) !Topology {
    const margin = size / 2 + 2;
    const w = lineWidth(face, text, size) + 2 * margin;
    const h = size + 2 * margin;
    const grid = try gpa.alloc(u8, w * h);
    defer gpa.free(grid);
    @memset(grid, 0);
    const at = @as(f32, @floatFromInt(margin)) + phase;
    try drawLine(gpa, face, grid, w, at, at, size, text, .{});
    return topology(gpa, grid, w, h);
}

test "letters keep their strokes and counters at label sizes, in every font" {
    // A letter at a label size has no more pieces and no more holes than the
    // same letter drawn huge: an `n` is one piece, an `e` has one hole, an `i`
    // is two pieces. A stroke that breaks adds a piece, and a white speck
    // inside a stroke adds a hole — which is what thin lower-case strokes did
    // when a dot needed half its area covered to be inked. Fewer is allowed:
    // at a small size a bold `i` has its dot touch its stem, and a small
    // counter fills in. Each size is tried at four sub-dot positions, because
    // a letter inside a word starts between dots.
    const gpa = std.testing.allocator;
    const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const sizes = [_]usize{ 16, 17, 19, 22, 24, 27, 32, 40, 48 };
    var failures: usize = 0;
    for (fonts) |font| {
        for (0..letters.len) |i| {
            const letter = letters[i .. i + 1];
            const want = try glyphTopology(gpa, &font.face, letter, 200, 0);
            for (sizes) |size| {
                for ([_]f32{ 0, 0.25, 0.5, 0.75 }) |phase| {
                    const got = try glyphTopology(gpa, &font.face, letter, size, phase);
                    if (got.pieces <= want.pieces and got.holes <= want.holes) continue;
                    failures += 1;
                    if (failures <= 20) std.debug.print("  {s} {s} at {d}+{d}: {d} pieces {d} holes, want {d} and {d}\n", .{ font.id, letter, size, phase, got.pieces, got.holes, want.pieces, want.holes });
                }
            }
        }
    }
    if (failures > 0) std.debug.print("  {d} broken\n", .{failures});
    try std.testing.expectEqual(@as(usize, 0), failures);
}
