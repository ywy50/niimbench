const std = @import("std");

/// The vendor's label catalogue, compiled into the binary from
/// `docs/labels/catalogue.json`. A roll's RFID tag carries a barcode and not
/// its size, and the printer does not report the size either, so the barcode is
/// the only handle a caller has. With the catalogue in the binary that handle
/// resolves offline, which is what lets a printer's roll set the canvas without
/// asking the cloud or the person at the keyboard.
pub const catalogue_json = @embedFile("catalogue.json");

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
    storage: std.json.Parsed([]const Raw),
    /// Rolls saved from the cloud, read from `saved_path` on first use and
    /// written back whole when one is added. Their strings live in `arena`.
    saved: std.StringArrayHashMapUnmanaged(Label) = .empty,
    arena: std.heap.ArenaAllocator,
    saved_read: bool = false,

    const Raw = struct {
        barcode: []const u8 = "",
        name: []const u8 = "",
        name_zh: []const u8 = "",
        width_mm: u16 = 0,
        height_mm: u16 = 0,
        paper_type: u8 = 1,
        machines: []const []const u8 = &.{},
        ours: []const []const u8 = &.{},
        codes: []const []const u8 = &.{},
    };

    pub fn deinit(self: *Catalogue) void {
        self.entries.deinit();
        self.storage.deinit();
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
            try self.saved.put(arena, raw.barcode, labelOf(raw));
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
/// malformed file is an error there rather than a surprise at the first print.
pub fn load(allocator: std.mem.Allocator) !Catalogue {
    return parse(allocator, catalogue_json);
}

fn parse(allocator: std.mem.Allocator, json: []const u8) !Catalogue {
    const storage = try std.json.parseFromSlice([]const Catalogue.Raw, allocator, json, .{
        .ignore_unknown_fields = true,
    });
    errdefer storage.deinit();
    var entries = std.StringHashMap(Label).init(allocator);
    errdefer entries.deinit();
    for (storage.value) |raw| {
        // A roll with no barcode cannot be looked up, and a zero dimension is
        // not a label.
        if (raw.barcode.len == 0 or raw.width_mm == 0 or raw.height_mm == 0) continue;
        try entries.put(raw.barcode, labelOf(raw));
        // The other barcodes the vendor gives the same roll, any of which its
        // tag may carry.
        for (raw.codes) |code| try entries.put(code, labelOf(raw));
    }
    return .{ .allocator = allocator, .entries = entries, .storage = storage, .arena = .init(allocator) };
}

fn labelOf(raw: Catalogue.Raw) Label {
    return .{
        .barcode = raw.barcode,
        .width_mm = raw.width_mm,
        .height_mm = raw.height_mm,
        .paper_type = raw.paper_type,
        .name = if (raw.name.len > 0) raw.name else raw.name_zh,
    };
}

test "a roll is found by any of its codes" {
    const gpa = std.testing.allocator;
    var catalogue = try parse(gpa,
        \\[{"barcode":"6971501224551","codes":["6972842743558","09132052"],"name":"RP12*22-260","width_mm":22,"height_mm":12,"paper_type":1}]
    );
    defer catalogue.deinit();
    for ([_][]const u8{ "6971501224551", "6972842743558", "09132052" }) |code| {
        const roll = catalogue.find(code) orelse return error.NoRoll;
        try std.testing.expectEqual(@as(u16, 22), roll.width_mm);
        try std.testing.expectEqualStrings("6971501224551", roll.barcode);
    }
    try std.testing.expect(catalogue.find("07132101") == null);
}

test "the embedded catalogue holds the roll this bench prints to" {
    const gpa = std.testing.allocator;
    var catalogue = try load(gpa);
    defer catalogue.deinit();
    try std.testing.expect(catalogue.count() > 100);

    // The 12x40 white roll a D110_M ships with, and the barcode its tag
    // answered with on this machine.
    const roll = catalogue.find("01222281") orelse return error.NoRoll;
    try std.testing.expectEqual(@as(u16, 12), roll.width_mm);
    try std.testing.expectEqual(@as(u16, 40), roll.height_mm);
    try std.testing.expectEqual(@as(u8, 1), roll.paper_type);

    try std.testing.expect(catalogue.find("99999999") == null);
}

test "a catalogue roll sizes a canvas for the head" {
    const gpa = std.testing.allocator;
    const raster = @import("raster.zig");
    const label = @import("label.zig");
    var catalogue = try load(gpa);
    defer catalogue.deinit();

    const roll = catalogue.find("01222281") orelse return error.NoRoll;
    // 12x40 mm at 203 dpi is 96x320 dots. This is the label the roll route
    // hands the editor when a printer answers with this barcode; the 2 mm the
    // D-series keeps back from the gap comes off when the page is printed.
    const width: usize = roll.width_mm * raster.dots_per_mm;
    const height: usize = roll.height_mm * raster.dots_per_mm;
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
