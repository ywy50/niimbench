const std = @import("std");

/// The vendor's label catalogue, compiled into the binary from what
/// `tools/fetch-labels.py` writes of `docs/labels/catalogue.json`: one roll
/// per line, its barcode, width and height in millimetres, then its other
/// codes, separated by spaces. A roll's RFID tag carries a barcode and not its
/// size, and the printer does not report the size either, so the barcode is the
/// only handle a caller has. With the catalogue in the binary that handle
/// resolves offline, which is what lets a printer's roll set the canvas without
/// asking the cloud or the person at the keyboard.
pub const catalogue_text = @embedFile("catalogue.txt");

/// Rolls the vendor's cloud answered for that the compiled-in list lacks,
/// kept in the folder the server runs from, beside its token file. A roll
/// asked about once is then known offline, without asking the cloud again.
/// `make add-rolls` writes them into `docs/labels/catalogue.json` for good.
pub const saved_path = ".niimbench.rolls.json";

pub const Label = struct {
    barcode: []const u8,
    width_mm: u16,
    height_mm: u16,
    paper_type: u8,
    name: []const u8,
};

/// One parsed catalogue, owned by the caller. `find` borrows from it.
pub const Catalogue = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(Label),
    /// Rolls saved from the cloud, read from `saved_path` on first use and
    /// written back whole when one is added. Their strings live in `arena`.
    saved: std.StringArrayHashMapUnmanaged(Label) = .empty,
    arena: std.heap.ArenaAllocator,
    saved_read: bool = false,

    /// A saved roll, as `save` writes it.
    const Raw = struct {
        barcode: []const u8 = "",
        name: []const u8 = "",
        width_mm: u16 = 0,
        height_mm: u16 = 0,
        paper_type: u8 = 1,
    };

    pub fn deinit(self: *Catalogue) void {
        self.entries.deinit();
        self.arena.deinit();
    }

    pub fn find(self: *const Catalogue, barcode: []const u8) ?Label {
        return self.entries.get(barcode);
    }

    pub fn findSaved(self: *const Catalogue, barcode: []const u8) ?Label {
        return self.saved.get(barcode);
    }

    /// The rolls saved in `dir`, read once. No file is no rolls saved yet.
    // ponytail: a malformed file is reported and then overwritten by the next
    // save; each roll it held costs one more cloud lookup.
    pub fn readSaved(self: *Catalogue, io: std.Io, dir: std.Io.Dir) !void {
        if (self.saved_read) return;
        self.saved_read = true;
        const arena = self.arena.allocator();
        const text = dir.readFileAlloc(io, saved_path, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const rolls = try std.json.parseFromSliceLeaky([]const Raw, arena, text, .{ .ignore_unknown_fields = true });
        for (rolls) |raw| {
            if (raw.barcode.len == 0 or raw.width_mm == 0 or raw.height_mm == 0) continue;
            try self.saved.put(arena, raw.barcode, .{
                .barcode = raw.barcode,
                .width_mm = raw.width_mm,
                .height_mm = raw.height_mm,
                .paper_type = raw.paper_type,
                .name = raw.name,
            });
        }
    }

    /// Keep a roll the cloud answered for. A barcode the compiled-in list
    /// holds is not saved: that copy stays the answer, and **Fetch** asks past
    /// it. Answers false when nothing was saved.
    pub fn save(self: *Catalogue, io: std.Io, dir: std.Io.Dir, label: Label) !bool {
        if (self.entries.contains(label.barcode)) return false;
        const arena = self.arena.allocator();
        const kept = self.saved.getPtr(label.barcode);
        const barcode = if (kept) |k| k.barcode else try arena.dupe(u8, label.barcode);
        try self.saved.put(arena, barcode, .{
            .barcode = barcode,
            .width_mm = label.width_mm,
            .height_mm = label.height_mm,
            .paper_type = label.paper_type,
            .name = try arena.dupe(u8, label.name),
        });
        const json = try std.json.Stringify.valueAlloc(self.allocator, self.saved.values(), .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        // Written aside and renamed over the old file, so a crash midway
        // leaves the previous rolls rather than half a file.
        var file = try dir.createFileAtomic(io, saved_path, .{ .replace = true });
        defer file.deinit(io);
        try file.file.writeStreamingAll(io, json);
        try file.replace(io);
        return true;
    }

    pub fn count(self: *const Catalogue) usize {
        return self.entries.count();
    }
};

/// Parse the embedded catalogue. It is read once, at plugin apply, and a
/// malformed line is an error there rather than a surprise at the first print.
/// The entries borrow from the text, which lives as long as the binary.
pub fn load(allocator: std.mem.Allocator) !Catalogue {
    return parse(allocator, catalogue_text);
}

fn parse(allocator: std.mem.Allocator, text: []const u8) !Catalogue {
    var entries = std.StringHashMap(Label).init(allocator);
    errdefer entries.deinit();
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const barcode = fields.next() orelse continue;
        const label: Label = .{
            .barcode = barcode,
            .width_mm = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch return error.BadCatalogue,
            .height_mm = std.fmt.parseInt(u16, fields.next() orelse "", 10) catch return error.BadCatalogue,
            .paper_type = 1,
            .name = "",
        };
        // A zero dimension is not a label.
        if (label.width_mm == 0 or label.height_mm == 0) continue;
        try entries.put(barcode, label);
        // The other barcodes the vendor gives the same roll, any of which its
        // tag may carry.
        while (fields.next()) |code| try entries.put(code, label);
    }
    return .{ .allocator = allocator, .entries = entries, .arena = .init(allocator) };
}

test "a roll is found by any of its codes" {
    const gpa = std.testing.allocator;
    var catalogue = try parse(gpa, "01222281 40 12\n6971501224551 22 12 6972842743558 09132052\n");
    defer catalogue.deinit();
    for ([_][]const u8{ "6971501224551", "6972842743558", "09132052" }) |code| {
        const roll = catalogue.find(code) orelse return error.NoRoll;
        try std.testing.expectEqual(@as(u16, 22), roll.width_mm);
        try std.testing.expectEqualStrings("6971501224551", roll.barcode);
    }
    try std.testing.expect(catalogue.find("07132101") == null);
    try std.testing.expectError(error.BadCatalogue, parse(gpa, "01222281 40\n"));
}

test "the embedded catalogue holds the roll this bench prints to" {
    const gpa = std.testing.allocator;
    var catalogue = try load(gpa);
    defer catalogue.deinit();
    try std.testing.expect(catalogue.count() > 10000);

    // The 12x40 white roll a D110_M ships with, and the barcode its tag
    // answered with on this machine. The vendor lists it length first; the
    // roll route turns it to face the head.
    const roll = catalogue.find("01222281") orelse return error.NoRoll;
    try std.testing.expectEqual(@as(u16, 40), roll.width_mm);
    try std.testing.expectEqual(@as(u16, 12), roll.height_mm);

    // A 12x22 roll whose tag carries one of the roll's other codes.
    const other = catalogue.find("6972842743558") orelse return error.NoRoll;
    try std.testing.expectEqual(@as(u16, 22), other.width_mm);
    try std.testing.expectEqual(@as(u16, 12), other.height_mm);

    try std.testing.expect(catalogue.find("99999999") == null);
}

test "a catalogue roll sizes a canvas for the head" {
    const gpa = std.testing.allocator;
    const raster = @import("raster.zig");
    const label = @import("label.zig");
    var catalogue = try load(gpa);
    defer catalogue.deinit();

    const roll = catalogue.find("01222281") orelse return error.NoRoll;
    // 12x40 mm at 203 dpi is 96x320 dots, the narrower side across the head
    // as the roll route turns it. This is the label the route hands the
    // editor when a printer answers with this barcode; the 2 mm the D-series
    // keeps back from the gap comes off when the page is printed.
    const width: usize = @as(usize, @min(roll.width_mm, roll.height_mm)) * raster.dots_per_mm;
    const height: usize = @as(usize, @max(roll.width_mm, roll.height_mm)) * raster.dots_per_mm;
    try std.testing.expectEqual(@as(usize, 96), width);
    try std.testing.expectEqual(@as(usize, 320), height);

    const gray = try label.render(gpa, width, height, &.{.{
        .text = "A",
        .x = 0,
        .y = 0,
        .size = 16,
    }}, "");
    defer gpa.free(gray.pixels);
    try std.testing.expectEqual(@as(usize, 96), gray.width);
    try std.testing.expectEqual(@as(usize, 320), gray.height);
}

test "a roll saved from the cloud is found again after a restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try load(gpa);
    defer first.deinit();
    try first.readSaved(io, tmp.dir);
    try std.testing.expect(first.findSaved("99999999") == null);
    const roll: Label = .{ .barcode = "99999999", .width_mm = 22, .height_mm = 12, .paper_type = 1, .name = "RP12*22-260 \"x\"" };
    try std.testing.expect(try first.save(io, tmp.dir, roll));
    // Saved again, as Fetch does: replaced, not listed twice.
    try std.testing.expect(try first.save(io, tmp.dir, roll));
    try std.testing.expectEqual(@as(usize, 1), first.saved.count());
    // The compiled-in list already answers for this one.
    try std.testing.expect(!try first.save(io, tmp.dir, .{ .barcode = "01222281", .width_mm = 1, .height_mm = 1, .paper_type = 1, .name = "" }));

    var second = try load(gpa);
    defer second.deinit();
    try second.readSaved(io, tmp.dir);
    const found = second.findSaved("99999999") orelse return error.NotSaved;
    try std.testing.expectEqual(@as(u16, 22), found.width_mm);
    try std.testing.expectEqual(@as(u16, 12), found.height_mm);
    try std.testing.expectEqualStrings("RP12*22-260 \"x\"", found.name);
    try std.testing.expect(second.findSaved("01222281") == null);
}
