const std = @import("std");

/// The vendor's label catalogue, compiled into the binary from
/// `docs/labels/catalogue.json`. A roll's RFID tag carries a barcode and not
/// its size, and the printer does not report the size either, so the barcode is
/// the only handle a caller has. With the catalogue in the binary that handle
/// resolves offline, which is what lets a printer's roll set the canvas without
/// asking the cloud or the person at the keyboard.
pub const catalogue_json = @embedFile("catalogue.json");

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

    const Raw = struct {
        barcode: []const u8 = "",
        name: []const u8 = "",
        name_zh: []const u8 = "",
        width_mm: u16 = 0,
        height_mm: u16 = 0,
        paper_type: u8 = 1,
        machines: []const []const u8 = &.{},
        ours: []const []const u8 = &.{},
    };

    pub fn deinit(self: *Catalogue) void {
        self.entries.deinit();
        self.storage.deinit();
    }

    pub fn find(self: *const Catalogue, barcode: []const u8) ?Label {
        return self.entries.get(barcode);
    }

    pub fn count(self: *const Catalogue) usize {
        return self.entries.count();
    }
};

/// Parse the embedded catalogue. It is read once, at plugin apply, and a
/// malformed file is an error there rather than a surprise at the first print.
pub fn load(allocator: std.mem.Allocator) !Catalogue {
    const storage = try std.json.parseFromSlice([]const Catalogue.Raw, allocator, catalogue_json, .{
        .ignore_unknown_fields = true,
    });
    errdefer storage.deinit();
    var entries = std.StringHashMap(Label).init(allocator);
    errdefer entries.deinit();
    for (storage.value) |raw| {
        // A roll with no barcode cannot be looked up, and a zero dimension is
        // not a label.
        if (raw.barcode.len == 0 or raw.width_mm == 0 or raw.height_mm == 0) continue;
        try entries.put(raw.barcode, .{
            .barcode = raw.barcode,
            .width_mm = raw.width_mm,
            .height_mm = raw.height_mm,
            .paper_type = raw.paper_type,
            .name = if (raw.name.len > 0) raw.name else raw.name_zh,
        });
    }
    return .{ .allocator = allocator, .entries = entries, .storage = storage };
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
    // 12x40 mm at 203 dpi is 96x320 dots, and the D-series keeps 2 mm back
    // from the gap, so the page is drawn 96x304. This is what the roll route
    // hands the editor when a printer answers with this barcode.
    const width: usize = roll.width_mm * raster.dots_per_mm;
    const height: usize = roll.height_mm * raster.dots_per_mm - raster.Model.d110.pageMargin();
    try std.testing.expectEqual(@as(usize, 96), width);
    try std.testing.expectEqual(@as(usize, 304), height);

    const gray = try label.render(gpa, width, height, &.{.{
        .text = "A",
        .x = 0,
        .y = 0,
        .size = 16,
    }}, "");
    defer gpa.free(gray.pixels);
    try std.testing.expectEqual(@as(usize, 96), gray.width);
    try std.testing.expectEqual(@as(usize, 304), gray.height);
}
