const std = @import("std");
const packet = @import("packet.zig");
const raster = @import("raster.zig");
const trace_mod = @import("trace.zig");

pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,
        read: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn write(self: Transport, data: []const u8) !void {
        return self.vtable.write(self.ptr, data);
    }

    pub fn read(self: Transport, buf: []u8) !usize {
        return self.vtable.read(self.ptr, buf);
    }

    pub fn close(self: Transport) void {
        self.vtable.close(self.ptr);
    }
};

/// Packet types the printer answers with, from the table in
/// docs/manuals/upstream/interfacing/proto.md: `0xdb` is the print error
/// frame, and type 0 is not assigned to any command in that table.
const print_error_type: u8 = 0xDB;
const unassigned_type: u8 = 0;

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    buffer: std.ArrayList(u8) = .empty,
    start: usize = 0,
    data_buf: [packet.Packet.max_data]u8 = undefined,
    /// Where a job's answers and status readings go. A blank page and a
    /// printed one both end `sent`; only these lines tell them apart.
    trace: ?*trace_mod.Trace = null,
    /// The printer is a D11 or D110 (`raster.Model.setsCopies`): the job asks
    /// its protocol version and sends the D-series sequence that version
    /// takes. The caller that knows the model sets it.
    d_series: bool = false,
    /// How many copies the D-series printer prints of the page: the job's
    /// page count and the page's copy count on protocol 4, `PrintQuantity`
    /// below it. A B-series sequence has no count, so its caller repeats the
    /// job instead and leaves this at 1.
    copies: u16 = 1,
    /// The code the printer gave when it last refused, as `PrintError` or in a
    /// status reading, 0 when it has not; `refusalName` says what it means.
    refusal: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, transport: Transport) Client {
        return .{ .allocator = allocator, .transport = transport };
    }

    pub fn deinit(self: *Client) void {
        self.buffer.deinit(self.allocator);
        self.transport.close();
    }

    /// The barcode on the roll in the printer. `null` means the tag is absent.
    /// The printer does not send millimetres; the barcode is what the Niimbot
    /// app looks up to learn the label size.
    /// The tag answers `0x1b` to this request, one past it, so the response
    /// offset is 1. Waiting for `0x1a` reads every answer as a foreign frame
    /// and ends in `NoResponse`.
    pub fn readBarcode(self: *Client) !?[]u8 {
        const roll = (try self.readRoll()) orelse return null;
        return roll.barcode;
    }

    /// The roll's tag: its barcode, which the caller owns, and the counts the
    /// printer keeps on it.
    pub fn readRoll(self: *Client) !?Roll {
        const response = try self.transceive(@backingInt(packet.Request.get_rfid), &.{1}, 1);
        const barcode = (try barcodeFromRfid(self.allocator, response.data)) orelse return null;
        return .{ .barcode = barcode, .counts = rfidCounts(response.data) };
    }

    pub const Roll = struct { barcode: []u8, counts: ?Counts };

    /// How many labels the roll's tag says the roll holds, and how many the
    /// printer has used: it adds one for every label it feeds, test prints
    /// and labels fed over again included, and it refuses a roll whose count
    /// has run out, whatever is left on it.
    pub const Counts = struct { total: u16, used: u16 };

    /// The counts after the tag's barcode and serial: total (u16) then used
    /// (u16), big-endian. Null when the answer stops short of them.
    pub fn rfidCounts(data: []const u8) ?Counts {
        if (data.len < 10) return null;
        const serial_at = 9 + @as(usize, data[8]);
        if (data.len <= serial_at) return null;
        const counts_at = serial_at + 1 + @as(usize, data[serial_at]);
        if (data.len < counts_at + 4) return null;
        return .{
            .total = @as(u16, data[counts_at]) << 8 | data[counts_at + 1],
            .used = @as(u16, data[counts_at + 2]) << 8 | data[counts_at + 3],
        };
    }

    /// What the printer says it is: its model id, and its firmware and
    /// hardware versions, from `PrinterInfo` (`0x40`) keys 8, 9 and 12, each
    /// answered `0x40` plus the key. A key the printer does not answer is null,
    /// so one it never learned does not hide the others.
    pub fn readInfo(self: *Client) !Info {
        var out: Info = .{};
        if (try self.infoKey(0x08)) |data| out.model_id = modelIdOf(data);
        if (try self.infoKey(0x09)) |data| out.firmware = Version.of(data);
        if (try self.infoKey(0x0c)) |data| out.hardware = Version.of(data);
        return out;
    }

    pub const Info = struct { model_id: ?u16 = null, firmware: ?Version = null, hardware: ?Version = null };

    /// Two bytes, major then minor: a D110_M's `04 1e` is firmware 4.30.
    pub const Version = struct {
        major: u8,
        minor: u8,

        fn of(data: []const u8) ?Version {
            if (data.len < 2) return null;
            return .{ .major = data[0], .minor = data[1] };
        }
    };

    /// The id in two bytes, big-endian; one byte `VV` is `VV 00`.
    fn modelIdOf(data: []const u8) ?u16 {
        return switch (data.len) {
            0 => null,
            1 => @as(u16, data[0]) << 8,
            else => @as(u16, data[0]) << 8 | data[1],
        };
    }

    /// One key's answer, valid until the next request, or null when the
    /// printer gives none.
    fn infoKey(self: *Client, key: u8) !?[]const u8 {
        const response = self.transceive(@backingInt(packet.Request.get_info), &.{key}, key) catch |err| switch (err) {
            error.NoResponse, error.PrinterUnsupported => return null,
            else => return err,
        };
        return response.data;
    }

    /// A wall-clock time with no zone: the printer keeps none, so the caller
    /// sends its own local time.
    pub const Clock = struct { year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8 };

    /// Set the printer's clock, which its date button prints and which starts
    /// at 1970 until something sets it. `PrinterConfig2` (`0x07`, answered
    /// `0x08`) in the form the protocol notes draw: 1 (set), then year (u16),
    /// month, day, hour, minute and second. A D110_M answers `01 01`, the
    /// first byte echoed and then 1 for done. Upstream's library puts an item
    /// byte, 8, in front; a D110_M answers that `08 00`, refused, so it is
    /// only the fallback for a printer that refuses the short form.
    pub fn setClock(self: *Client, t: Clock) !bool {
        const year_hi: u8 = @intCast(t.year >> 8);
        const year_lo: u8 = @intCast(t.year & 0xFF);
        if (try self.configDone(&.{ 1, year_hi, year_lo, t.month, t.day, t.hour, t.minute, t.second })) return true;
        return self.configDone(&.{ 8, 1, year_hi, year_lo, t.month, t.day, t.hour, t.minute, t.second });
    }

    /// A `PrinterConfig2` answer echoes the first byte sent; the second is the
    /// result. Reading the first, as a simple answer, took the echo for done.
    fn configDone(self: *Client, data: []const u8) !bool {
        const response = try self.transceive(@backingInt(packet.Request.printer_config2), data, 1);
        return response.data.len >= 2 and response.data[1] != 0;
    }

    pub fn printGray(
        self: *Client,
        io: ?std.Io,
        pixels: []const u8,
        width: usize,
        height: usize,
        density: u8,
    ) !void {
        // The bound first: below it width*height cannot wrap.
        if (width > 65535 or height > 65535) return error.BadSize;
        if (pixels.len != width * height) return error.BadSize;
        if (density < 1 or density > 5) return error.BadDensity;
        // A D-series printer on protocol 4, the D110_M among them, takes the
        // sequence upstream calls D110M_V4, which tells it the job's page
        // count and the page's copy count. Sent the older D110 sequence, which
        // tells it neither, a D110_M printed a label twice, both copies whole,
        // even with PrintQuantity set to 1.
        const v4 = self.d_series and self.protocolVersion() >= 4;
        // cordis-boundary: from `start_print` on, the job is the printer's.
        // Whatever fails after it, a refused page size or a row or end_page
        // left unanswered, still ends with end_print, so the printer is not
        // left in a job nobody finishes.
        var closed = false;
        errdefer if (!closed) self.endPrint(io) catch {};
        if (v4) try self.openPageV4(width, height, density) else try self.openPage(width, height, density);
        const row_len = raster.packedRowBytes(width);
        const payload = try self.allocator.alloc(u8, row_len + 6);
        defer self.allocator.free(payload);
        const ahead = try self.allocator.alloc(u8, row_len);
        defer self.allocator.free(ahead);
        // A run of identical rows goes as one packet with a repeat count, and
        // a blank run as one `PrintEmptyRow`. Each packet waits for the
        // printer's acknowledgement over Bluetooth, about 25 ms, and a text
        // label is mostly white: one packet per row took 7 s for 304 rows.
        // The count is one byte, so a run stops at 255.
        var packets: usize = 0;
        var y: usize = 0;
        while (y < height) {
            const row = payload[6..][0..row_len];
            raster.packRow(pixels[y * width ..][0..width], row);
            var run: usize = 1;
            while (y + run < height and run < 255) : (run += 1) {
                raster.packRow(pixels[(y + run) * width ..][0..width], ahead);
                if (!std.mem.eql(u8, row, ahead)) break;
            }
            if (std.mem.allEqual(u8, row, 0)) {
                try self.send(.empty_row, &.{ @intCast(y >> 8), @intCast(y & 0xFF), @intCast(run) });
            } else {
                const header = raster.rowHeader(@intCast(y), @intCast(run));
                @memcpy(payload[0..6], &header);
                try self.send(.image, payload);
            }
            packets += 1;
            y += run;
        }
        const end_page_ok = try self.command(.end_page, &.{1}, 1);
        self.note("{d} rows in {d} packets sent, end_page={d}", .{ height, packets, @intFromBool(end_page_ok) });
        // An idle printer answers PrintEnd with 0x01 before the motor starts.
        // Closing on that feeds nothing, and the job would still look printed.
        // PrintStatus is the signal that this page ran. PrintEnd follows it.
        self.waitForPage(io) catch |err| switch (err) {
            // A head with no PrintStatus finishes by polling PrintEnd. Those
            // heads answer 0x00 while the page is still out.
            error.PrinterUnsupported => {
                self.note("no PrintStatus, polling end_print", .{});
                closed = true;
                return self.confirmByEndPrint(io);
            },
            else => {
                // cordis-boundary: the page is already on the wire. end_print
                // closes the job, including a page the counter never counted.
                closed = true;
                self.endPrint(io) catch {};
                return err;
            },
        };
        // cordis-boundary: the page is already on the wire. end_print is the
        // compensation that tells the printer the job is finished.
        closed = true;
        try self.endPrint(io);
        // The V4 sequence ends with a heartbeat nothing waits for: some of
        // those printers drop the first packet after PrintEnd.
        if (v4) self.send(.heartbeat, &.{1}) catch |err| self.note("heartbeat after end_print: {s}", .{@errorName(err)});
    }

    /// The setup of a page in the older sequence: B-series, and D-series below
    /// protocol 4, which also clear the page buffer and set one copy as the
    /// D11 and D110 sequences upstream do. An answer of 0 is recorded, not
    /// refused: which answers a blank first page carries is what the trace has
    /// to show.
    fn openPage(self: *Client, width: usize, height: usize, density: u8) !void {
        const density_ok = try self.command(.set_density, &.{density}, 16);
        const type_ok = try self.command(.set_label_type, &.{1}, 16);
        const start_ok = try self.command(.start_print, &.{1}, 1);
        const clear_ok = if (self.d_series) try self.command(.allow_print_clear, &.{1}, 16) else true;
        const page_ok = try self.command(.start_page, &.{1}, 1);
        // `SetPageSize` is `RR RR CC CC`: the row count first, the column count
        // second. The row count is the page's length down the tape, so a page
        // that puts the width here tells the printer its page is 96 rows long
        // and the rest of the image is dropped: on a 12x40 roll the print stops
        // about 12 mm in.
        var dim = [_]u8{
            @intCast((height >> 8) & 0xFF),
            @intCast(height & 0xFF),
            @intCast((width >> 8) & 0xFF),
            @intCast(width & 0xFF),
        };
        const dim_ok = try self.command(.set_dimension, &dim, 1);
        if (self.d_series) {
            const quantity_ok = try self.command(.set_quantity, &.{ @intCast(self.copies >> 8), @intCast(self.copies & 0xFF) }, 1);
            self.note("answers density={d} type={d} start={d} clear={d} page={d} dimension={d} quantity={d}", .{
                @intFromBool(density_ok), @intFromBool(type_ok), @intFromBool(start_ok),    @intFromBool(clear_ok),
                @intFromBool(page_ok),    @intFromBool(dim_ok),  @intFromBool(quantity_ok),
            });
        } else {
            self.note("answers density={d} type={d} start={d} page={d} dimension={d}", .{
                @intFromBool(density_ok), @intFromBool(type_ok), @intFromBool(start_ok),
                @intFromBool(page_ok),    @intFromBool(dim_ok),
            });
        }
    }

    /// The setup of a page in upstream's D110M_V4 sequence, for a D-series
    /// printer on protocol 4: label type before density, a 9-byte PrintStart
    /// that gives the job its page count, no PageStart, and a 13-byte
    /// SetPageSize that gives the page its copy count. One page printed
    /// `copies` times is a job of `copies` pages.
    fn openPageV4(self: *Client, width: usize, height: usize, density: u8) !void {
        const copies_hi: u8 = @intCast(self.copies >> 8);
        const copies_lo: u8 = @intCast(self.copies & 0xFF);
        const type_ok = try self.command(.set_label_type, &.{1}, 16);
        const density_ok = try self.command(.set_density, &.{density}, 16);
        // Pages (u16), four zeros, page colour, speed, flag.
        const start_ok = try self.command(.start_print, &.{ copies_hi, copies_lo, 0, 0, 0, 0, 0, 0, 0 }, 1);
        // Upstream sends this without waiting: some of these printers drop
        // the first packet after PrintStart. An answer that does come is
        // skipped while the next command waits for its own.
        try self.send(.get_print_status, &.{1});
        // Rows and columns as in the older sequence, then copies (u16), cut
        // height (u16), cut type, a zero, send-all and part height (u16).
        const dim = [_]u8{
            @intCast((height >> 8) & 0xFF), @intCast(height & 0xFF),
            @intCast((width >> 8) & 0xFF),  @intCast(width & 0xFF),
            copies_hi,                      copies_lo,
            0,                              0,
            0,                              0,
            0,                              0,
            0,
        };
        const dim_ok = try self.command(.set_dimension, &dim, 1);
        self.note("protocol 4 answers type={d} density={d} start={d} dimension={d}", .{
            @intFromBool(type_ok), @intFromBool(density_ok), @intFromBool(start_ok), @intFromBool(dim_ok),
        });
    }

    /// The printer's protocol version, learned the way the official clients
    /// do: `Connect` answers 2 for version 1 and 3 for version 3 and up, and
    /// then `PrinterStatusData` carries the version in its bytes 11 and 12.
    /// 0 for a printer that answers neither, which keeps the older sequence.
    fn protocolVersion(self: *Client) u8 {
        const version: u8 = blk: {
            const connected = self.connect() catch |err| {
                self.note("connect: {s}", .{@errorName(err)});
                break :blk 0;
            };
            if (connected == 2) break :blk 1;
            if (connected != 3) break :blk 0;
            const response = self.transceive(@backingInt(packet.Request.printer_status_data), &.{1}, 16) catch |err| {
                self.note("printer status data: {s}", .{@errorName(err)});
                break :blk 0;
            };
            if (response.data.len < 13) break :blk 0;
            const n = @as(u16, response.data[11]) * 100 + response.data[12];
            break :blk if (n >= 302) 5 else if (n >= 300) 4 else if (n >= 204) 3 else 0;
        };
        self.note("protocol {d}", .{version});
        return version;
    }

    /// `Connect` is the one request with a prefix byte, `0x03`, before the
    /// frame. Its answer is `0xC2`, one byte.
    fn connect(self: *Client) !u8 {
        var wire: [packet.Packet.max_wire + 1]u8 = undefined;
        wire[0] = 0x03;
        const bytes = try (packet.Packet{ .packet_type = @backingInt(packet.Request.connect), .data = &.{1} }).toBytes(wire[1..]);
        try self.transport.write(wire[0 .. bytes.len + 1]);
        const response = try self.awaitPacket(@backingInt(packet.Request.connect) + 1);
        if (response.data.len == 0) return error.ShortResponse;
        return response.data[0];
    }

    /// Polls after `PageEnd`. About five seconds at 200ms, past one feed of a
    /// 40 mm label. A page still moving at the end is `PrintDidNotFinish`.
    const print_status_polls: u8 = 25;

    const PageStatus = struct {
        page: u16,
        print_pct: u8,
        feed_pct: u8,
    };

    /// `PrintStatus` (`0xA3`) is answered as `0xB3`, sixteen past the request.
    fn printStatus(self: *Client) !PageStatus {
        const response = try self.transceive(@backingInt(packet.Request.get_print_status), &.{1}, 16);
        self.note("status {x}", .{response.data});
        if (response.data.len < 4) return error.ShortResponse;
        // Byte 6 is an error code: cover, paper, battery, the roll's tag.
        // Ten data bytes with one set mean the printer stopped. A D110_M
        // answers eight, and sets it after a page it still printed, as when
        // the tag could not be written; that one is said, not refused, since
        // the label is out.
        if (response.data.len >= 7 and response.data[6] != 0) {
            self.refusal = response.data[6];
            if (response.data.len >= 10) return error.PrinterRefused;
            if (self.trace) |t| t.warn("printer", "status reports {s} (0x{x:0>2})", .{ refusalName(self.refusal), self.refusal });
        }
        return .{
            .page = @as(u16, response.data[0]) << 8 | response.data[1],
            .print_pct = response.data[2],
            .feed_pct = response.data[3],
        };
    }

    /// The first reading is the printer's leftover counter. Success is that
    /// counter moving by the job's copies, or the print progress leaving 100
    /// and returning with the page at the copy count. A reading that never
    /// changes is a skipped label. The polls allowed grow with the copies.
    fn waitForPage(self: *Client, io: ?std.Io) !void {
        const target: u16 = if (self.d_series) self.copies else 1;
        var baseline: ?u16 = null;
        var saw_motion = false;
        var tries: u32 = 0;
        while (tries < @as(u32, print_status_polls) * target) : (tries += 1) {
            const status = self.printStatus() catch |err| switch (err) {
                error.NoResponse => {
                    self.note("status: no answer", .{});
                    if (io) |live| try live.sleep(.fromMilliseconds(200), .awake);
                    continue;
                },
                else => return err,
            };
            if (baseline == null) baseline = status.page;
            if (status.print_pct < 100) saw_motion = true;
            // Wider than the counter, which a printer near 65535 would
            // otherwise overflow, stopping the server.
            const advanced = @as(u32, status.page) >= @as(u32, baseline orelse 0) + target;
            const settled = saw_motion and status.page >= target and status.print_pct >= 100 and status.feed_pct >= 100;
            // A counter past the last copy while the head is printing again is
            // a copy the job did not ask for.
            if (advanced and status.print_pct < 100) {
                if (self.trace) |t| t.warn("printer", "page {d} done and another copy started", .{status.page});
            }
            if (advanced or settled) return;
            if (io) |live| try live.sleep(.fromMilliseconds(200), .awake);
        }
        if (saw_motion) return error.PrintDidNotFinish;
        return error.PrintSkipped;
    }

    fn note(self: *Client, comptime format: []const u8, args: anytype) void {
        if (self.trace) |t| t.info("printer", format, args);
    }

    fn endPrint(self: *Client, io: ?std.Io) !void {
        // cordis-boundary: the page is already on the wire. end_print is the
        // compensation that tells the printer the job is finished.
        var tries: u8 = 0;
        while (tries < 10) : (tries += 1) {
            const done = try self.command(.end_print, &.{1}, 1);
            if (done) {
                self.note("end_print accepted on try {d}", .{tries + 1});
                return;
            }
            if (io) |live| try live.sleep(.fromMilliseconds(100), .awake);
        }
        return error.PrintDidNotFinish;
    }

    fn confirmByEndPrint(self: *Client, io: ?std.Io) !void {
        // cordis-boundary: the page is already on the wire. end_print is the
        // compensation that tells the printer the job is finished.
        var tries: u8 = 0;
        while (tries < 50) : (tries += 1) {
            const done = try self.command(.end_print, &.{1}, 1);
            if (done) {
                self.note("end_print accepted on try {d}", .{tries + 1});
                return;
            }
            if (io) |live| try live.sleep(.fromMilliseconds(100), .awake);
        }
        return error.PrintDidNotFinish;
    }

    pub fn barcodeFromRfid(allocator: std.mem.Allocator, data: []const u8) !?[]u8 {
        // One byte is the answer for no tag. The first byte of a real answer
        // is the tag UUID's, which may be 0.
        if (data.len < 10) return null;
        const barcode_len: usize = data[8];
        if (barcode_len == 0 or data.len < 9 + barcode_len) return error.BadRfid;
        const barcode = data[9..][0..barcode_len];
        for (barcode) |c| {
            if (c < '0' or c > '9') return error.BadRfid;
        }
        return try allocator.dupe(u8, barcode);
    }

    fn command(self: *Client, req: packet.Request, data: []const u8, resp_offset: u8) !bool {
        const response = try self.transceive(@backingInt(req), data, resp_offset);
        if (response.data.len == 0) return error.ShortResponse;
        return response.data[0] != 0;
    }

    fn send(self: *Client, req: packet.Request, data: []const u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{ .packet_type = @backingInt(req), .data = data }).toBytes(&wire);
        try self.transport.write(bytes);
    }

    fn transceive(self: *Client, req: u8, data: []const u8, resp_offset: u8) !packet.Packet {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{ .packet_type = req, .data = data }).toBytes(&wire);
        try self.transport.write(bytes);
        return self.awaitPacket(req +% resp_offset);
    }

    /// The next answer of type `expect`, skipping any other frame before it.
    fn awaitPacket(self: *Client, expect: u8) !packet.Packet {
        var attempt: u8 = 0;
        while (attempt < 6) : (attempt += 1) {
            if (try self.pop(expect)) |found| return found;
            var tmp: [1024]u8 = undefined;
            const n = try self.transport.read(&tmp);
            if (n == 0) continue;
            try self.buffer.appendSlice(self.allocator, tmp[0..n]);
        }
        if (try self.pop(expect)) |found| return found;
        return error.NoResponse;
    }

    fn pop(self: *Client, expect: u8) !?packet.Packet {
        while (self.buffer.items.len - self.start > 4) {
            const available = self.buffer.items[self.start..];
            // A frame starts `55 55`. A stray byte, or the tail of a frame an
            // earlier read gave up on, is stepped over one byte at a time;
            // read as a frame it ended the job or waited out a timeout.
            if (available[0] != 0x55 or available[1] != 0x55) {
                self.start += 1;
                continue;
            }
            const pkt_len = @as(usize, available[3]) + 7;
            if (available.len < pkt_len) break;
            const parsed = packet.Packet.fromBytes(available[0..pkt_len], &self.data_buf) catch {
                self.start += 1;
                continue;
            };
            self.start += pkt_len;
            if (self.start == self.buffer.items.len) {
                self.buffer.clearRetainingCapacity();
                self.start = 0;
            }
            if (parsed.packet_type == print_error_type) {
                self.refusal = if (parsed.data.len > 0) parsed.data[0] else 0;
                if (self.trace) |t| t.warn("printer", "refused: {s} (0x{x:0>2})", .{ refusalName(self.refusal), self.refusal });
                return error.PrinterRefused;
            }
            if (parsed.packet_type == unassigned_type) return error.PrinterUnsupported;
            if (parsed.packet_type == expect) {
                // parsed.data points into data_buf, so the caller must finish
                // with it before the next pop.
                return parsed;
            }
        }
        return null;
    }
};

/// The printer's own name for a refusal code, as the protocol notes list them
/// (docs/manuals/upstream/interfacing/proto.md, Printer error codes).
pub fn refusalName(code: u8) []const u8 {
    const names = [_][]const u8{
        "CoverOpen",                      "LackPaper",                "LowBattery",             "BatteryException",
        "UserCancel",                     "DataError",                "Overheat",               "PaperOutException",
        "PrinterBusy",                    "NoPrinterHead",            "TemperatureLow",         "PrinterHeadLoose",
        "NoRibbon",                       "WrongRibbon",              "UsedRibbon",             "WrongPaper",
        "SetPaperFail",                   "SetPrintModeFail",         "SetPrintDensityFail",    "WriteRfidFail",
        "SetMarginFail",                  "CommunicationException",   "Disconnect",             "CanvasParameterError",
        "RotationParameterException",     "JsonParameterException",   "B3sAbnormalPaperOutput", "ECheckPaper",
        "RfidTagNotWritten",              "SetPrintDensityNoSupport", "SetPrintModeNoSupport",  "SetPrintLabelMaterialError",
        "SetPrintLabelMaterialNoSupport", "NotSupportWrittenRfid",
    };
    if (code == 0 or code > names.len) return "Unknown";
    return names[code - 1];
}

test "a printer says its model id, firmware and hardware" {
    // What a D110_M answered: model 0x0910 (2320), firmware 04 1e, hardware
    // 04 01. A printer that leaves a key unanswered gets null for it.
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    try script.push(.get_info, 0x08, &.{ 0x09, 0x10 });
    try script.push(.get_info, 0x09, &.{ 0x04, 0x1e });
    try script.push(.get_info, 0x0c, &.{ 0x04, 0x01 });
    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const info = try client.readInfo();
    try std.testing.expectEqual(@as(u16, 2320), info.model_id.?);
    try std.testing.expectEqual(Client.Version{ .major = 4, .minor = 30 }, info.firmware.?);
    try std.testing.expectEqual(Client.Version{ .major = 4, .minor = 1 }, info.hardware.?);
    var frames = try framesWritten(gpa, script.written.items);
    defer frames.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), frames.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 1, 0x09 }, frames.items[1][0..3]);
}

const Script = struct {
    allocator: std.mem.Allocator,
    written: std.ArrayList(u8) = .empty,
    inbound: std.ArrayList(u8) = .empty,
    pos: usize = 0,

    fn deinit(self: *Script) void {
        self.written.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
    }

    fn pushPage(self: *Script, page: u16, print_pct: u8, feed_pct: u8) !void {
        const data = [_]u8{
            @intCast((page >> 8) & 0xFF),
            @intCast(page & 0xFF),
            print_pct,
            feed_pct,
        };
        try self.push(.get_print_status, 16, &data);
    }

    /// A page the counter watched: not started, then counted, then ended.
    fn pushFinishedPage(self: *Script) !void {
        const ok = [_]u8{1};
        try self.pushPage(0, 0, 0);
        try self.pushPage(1, 100, 100);
        try self.push(.end_print, 1, &ok);
    }

    fn push(self: *Script, req: packet.Request, offset: u8, data: []const u8) !void {
        var wire: [packet.Packet.max_wire]u8 = undefined;
        const bytes = try (packet.Packet{
            .packet_type = @backingInt(req) +% offset,
            .data = data,
        }).toBytes(&wire);
        try self.inbound.appendSlice(self.allocator, bytes);
    }

    fn write(ptr: *anyopaque, data: []const u8) !void {
        const self: *Script = @ptrCast(@alignCast(ptr));
        try self.written.appendSlice(self.allocator, data);
    }

    fn read(ptr: *anyopaque, buf: []u8) !usize {
        const self: *Script = @ptrCast(@alignCast(ptr));
        if (self.pos >= self.inbound.items.len) return 0;
        const n = @min(buf.len, self.inbound.items.len - self.pos);
        @memcpy(buf[0..n], self.inbound.items[self.pos..][0..n]);
        self.pos += n;
        return n;
    }

    fn close(_: *anyopaque) void {}
};

fn scriptTransport(script: *Script) Transport {
    return .{
        .ptr = script,
        .vtable = &.{ .write = Script.write, .read = Script.read, .close = Script.close },
    };
}

test "the roll tag is read through the client" {
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    // Captured from a D110_M: the tag answering RfidInfo (0x1a).
    const tag = [_]u8{ 0x88, 0x1d, 0x2a, 0x0f, 0x7a, 0x1e, 0x10, 0x80, 0x08, 0x30, 0x31, 0x32, 0x32, 0x32, 0x32, 0x38, 0x31, 0x10, 0x50, 0x5a, 0x31, 0x49, 0x36, 0x30, 0x39, 0x34, 0x35, 0x30, 0x30, 0x30, 0x30, 0x38, 0x30, 0x39, 0x00, 0xba, 0x00, 0x23, 0x01 };
    try script.push(.get_rfid, 1, &tag);

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const roll = (try client.readRoll()) orelse return error.NoBarcode;
    defer gpa.free(roll.barcode);
    try std.testing.expectEqualStrings("01222281", roll.barcode);
    // 0x00ba labels on the roll, 0x0023 used when it was captured.
    try std.testing.expectEqual(Client.Counts{ .total = 186, .used = 35 }, roll.counts.?);
}

test "a refusal keeps the printer's code, and the code has its name" {
    const gpa = std.testing.allocator;
    const ok = [_]u8{1};
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    var wire: [packet.Packet.max_wire]u8 = undefined;
    try script.inbound.appendSlice(gpa, try (packet.Packet{ .packet_type = 0xDB, .data = &.{0x14} }).toBytes(&wire));
    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try std.testing.expectError(error.PrinterRefused, client.printGray(null, &pixels, 8, 1, 3));
    try std.testing.expectEqual(@as(u8, 0x14), client.refusal);
    try std.testing.expectEqualStrings("WriteRfidFail", refusalName(client.refusal));
    try std.testing.expectEqualStrings("CoverOpen", refusalName(1));
    try std.testing.expectEqualStrings("NotSupportWrittenRfid", refusalName(0x22));
    try std.testing.expectEqualStrings("Unknown", refusalName(0x23));
}

test "a tag whose uuid starts with 0 is a tag" {
    // Only a one-byte answer means no tag; the first byte of a real one is
    // the tag UUID's, and reading it as a presence flag lost such a roll.
    const tag = [_]u8{ 0x00, 0x1d, 0x2a, 0x0f, 0x7a, 0x1e, 0x10, 0x80, 0x08, 0x30, 0x31, 0x32, 0x32, 0x32, 0x32, 0x38, 0x31, 0x01, 0x50, 0x00, 0xba, 0x00, 0x23, 0x01 };
    const barcode = (try Client.barcodeFromRfid(std.testing.allocator, &tag)).?;
    defer std.testing.allocator.free(barcode);
    try std.testing.expectEqualStrings("01222281", barcode);
    try std.testing.expectEqual(Client.Counts{ .total = 186, .used = 35 }, Client.rfidCounts(&tag).?);
    try std.testing.expect((try Client.barcodeFromRfid(std.testing.allocator, &.{0x00})) == null);
}

test "rfid barcode is the digits after the uuid" {
    const gpa = std.testing.allocator;
    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 4, '1', '5', '3', '0' };
    const barcode = (try printerBarcode(&data)).?;
    defer gpa.free(barcode);
    try std.testing.expectEqualStrings("1530", barcode);
    try std.testing.expect((try printerBarcode(&[_]u8{0})) == null);
}

fn printerBarcode(data: []const u8) !?[]u8 {
    return Client.barcodeFromRfid(std.testing.allocator, data);
}

test "the page size puts the row count first" {
    // `SetPageSize` is `RR RR CC CC` and the row count is the page's length
    // down the tape. Sending the width there tells the printer the page is 96
    // rows long, and it drops the rest of the image.
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushFinishedPage();

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    // 96 dots across the head, one row long.
    const pixels = @as([96]u8, @splat(0));
    try client.printGray(null, &pixels, 96, 1, 3);

    const wire = script.written.items;
    var off: usize = 0;
    var found = false;
    while (off < wire.len) {
        const len = @as(usize, wire[off + 3]) + 7;
        if (wire[off + 2] == @backingInt(packet.Request.set_dimension)) {
            // 96 columns, 1 row: the row count is the first word.
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x60 }, wire[off + 4 .. off + 8]);
            found = true;
        }
        off += len;
    }
    try std.testing.expect(found);
}

/// Every frame a job wrote, as `[type, length, data...]`, in order. The
/// `0x03` that prefixes `Connect` alone is stepped over.
fn framesWritten(gpa: std.mem.Allocator, wire: []const u8) !std.ArrayList([]const u8) {
    var found: std.ArrayList([]const u8) = .empty;
    errdefer found.deinit(gpa);
    var off: usize = 0;
    while (off + 7 <= wire.len) {
        if (wire[off] == 0x03) off += 1;
        const len = @as(usize, wire[off + 3]);
        try found.append(gpa, wire[off + 2 .. off + 4 + len]);
        off += len + 7;
    }
    return found;
}

/// The row packets a job wrote, as `[type, length, data...]`, in order.
fn rowPackets(gpa: std.mem.Allocator, wire: []const u8) !std.ArrayList([]const u8) {
    var found = try framesWritten(gpa, wire);
    errdefer found.deinit(gpa);
    var kept: usize = 0;
    for (found.items) |frame| {
        if (frame[0] == @backingInt(packet.Request.empty_row) or frame[0] == @backingInt(packet.Request.image)) {
            found.items[kept] = frame;
            kept += 1;
        }
    }
    found.shrinkRetainingCapacity(kept);
    return found;
}

fn printScripted(gpa: std.mem.Allocator, script: *Script, pixels: []const u8, width: usize, height: usize) !void {
    const ok = [_]u8{1};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushFinishedPage();
    var client = Client.init(gpa, scriptTransport(script));
    defer client.deinit();
    try client.printGray(null, pixels, width, height, 3);
}

test "blank and repeated rows go as one packet per run" {
    // Over Bluetooth every packet waits for the printer's acknowledgement,
    // and a label is mostly white. Rows 0-2 white, 3-5 the same dots, 6 other
    // dots, 7-9 white: four packets, not ten.
    const gpa = std.testing.allocator;
    var page: [8 * 10]u8 = @splat(255);
    for (3..6) |y| page[y * 8] = 0;
    page[6 * 8 + 7] = 0;
    {
        var script = Script{ .allocator = gpa };
        defer script.deinit();
        try printScripted(gpa, &script, &page, 8, 10);
        var packets = try rowPackets(gpa, script.written.items);
        defer packets.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 4), packets.items.len);
        try std.testing.expectEqualSlices(u8, &.{ 0x84, 3, 0, 0, 3 }, packets.items[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0x85, 7, 0, 3, 0, 0, 0, 3, 0x80 }, packets.items[1]);
        try std.testing.expectEqualSlices(u8, &.{ 0x85, 7, 0, 6, 0, 0, 0, 1, 0x01 }, packets.items[2]);
        try std.testing.expectEqualSlices(u8, &.{ 0x84, 3, 0, 7, 3 }, packets.items[3]);
    }
    // The count is one byte: 300 white rows are a run of 255, then one of 45
    // that starts at row 255.
    {
        const white: [8 * 300]u8 = @splat(255);
        var script = Script{ .allocator = gpa };
        defer script.deinit();
        try printScripted(gpa, &script, &white, 8, 300);
        var packets = try rowPackets(gpa, script.written.items);
        defer packets.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 2), packets.items.len);
        try std.testing.expectEqualSlices(u8, &.{ 0x84, 3, 0, 0, 255 }, packets.items[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0x84, 3, 0, 255, 45 }, packets.items[1]);
    }
}

test "print sends the command sequence a Niimbot print expects" {
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushFinishedPage();

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);

    var types: [12]u8 = undefined;
    var count: usize = 0;
    var off: usize = 0;
    while (off < script.written.items.len) {
        const len = @as(usize, script.written.items[off + 3]) + 7;
        types[count] = script.written.items[off + 2];
        count += 1;
        off += len;
    }
    try std.testing.expectEqualSlices(u8, &[_]u8{
        @backingInt(packet.Request.set_density),
        @backingInt(packet.Request.set_label_type),
        @backingInt(packet.Request.start_print),
        @backingInt(packet.Request.start_page),
        @backingInt(packet.Request.set_dimension),
        @backingInt(packet.Request.image),
        @backingInt(packet.Request.end_page),
        @backingInt(packet.Request.get_print_status),
        @backingInt(packet.Request.get_print_status),
        @backingInt(packet.Request.end_print),
    }, types[0..count]);
}

test "a job records each answer and status reading in the trace" {
    // A blank page and a printed one both end `sent`. The refused page start
    // and the raw status bytes are what tell them apart afterwards.
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(trace_mod.Trace.Entry, 16);
    defer gpa.free(entries);
    for (entries) |*entry| entry.* = .{};
    var trace = trace_mod.Trace{ .allocator = gpa, .entries = entries };

    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    const refused = [_]u8{0};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &refused);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushFinishedPage();

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    client.trace = &trace;
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);

    try std.testing.expectEqualStrings("answers density=1 type=1 start=1 page=0 dimension=1", trace.at(0).messageText());
    try std.testing.expectEqualStrings("1 rows in 1 packets sent, end_page=1", trace.at(1).messageText());
    try std.testing.expectEqualStrings("status 00000000", trace.at(2).messageText());
    try std.testing.expectEqualStrings("status 00016464", trace.at(3).messageText());
    try std.testing.expectEqualStrings("end_print accepted on try 1", trace.at(4).messageText());
}

test "a D-series printer on protocol 4 gets the V4 sequence: one page, one copy" {
    // A D110_M answers Connect with 3 and PrinterStatusData with 3,01 in
    // bytes 11-12: protocol 4. Sent the older D110 sequence, it printed a
    // label twice. Upstream's D110M_V4 sequence tells it one page and one copy.
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    try script.push(.connect, 1, &.{3});
    try script.push(.printer_status_data, 16, &.{ 0x30, 0x30, 0x23, 0x28, 0x00, 0xc8, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x03, 0x01, 0x12, 0xee, 0x00 });
    try script.push(.set_label_type, 16, &ok);
    try script.push(.set_density, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.pushPage(0, 100, 100); // the answer to the status nothing waits for
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushFinishedPage();

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    client.d_series = true;
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);

    var frames = try framesWritten(gpa, script.written.items);
    defer frames.deinit(gpa);
    // The Connect frame goes out behind its 0x03 prefix.
    try std.testing.expectEqual(@as(u8, 0x03), script.written.items[0]);
    const expected = [_][]const u8{
        &.{ 0xC1, 1, 1 },
        &.{ 0xA5, 1, 1 },
        &.{ 0x23, 1, 1 },
        &.{ 0x21, 1, 3 },
        // One page in the job.
        &.{ 0x01, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0 },
        &.{ 0xA3, 1, 1 },
        // One row of eight dots, one copy, no cut.
        &.{ 0x13, 13, 0, 1, 0, 8, 0, 1, 0, 0, 0, 0, 0, 0, 0 },
    };
    for (expected, 0..) |want, i| try std.testing.expectEqualSlices(u8, want, frames.items[i]);
    // Then the row, PageEnd, the status polls, PrintEnd, and the heartbeat.
    const last = frames.items[frames.items.len - 1];
    try std.testing.expectEqualSlices(u8, &.{ 0xDC, 1, 1 }, last);
    for (frames.items) |frame| {
        try std.testing.expect(frame[0] != @backingInt(packet.Request.start_page));
        try std.testing.expect(frame[0] != @backingInt(packet.Request.allow_print_clear));
        try std.testing.expect(frame[0] != @backingInt(packet.Request.set_quantity));
    }
}

test "copies go to a D-series printer as its own count, and the job waits for all of them" {
    // Protocol 4: three copies are a job of three pages and a page of three
    // copies. Below it: PrintQuantity 3. The job ends when the counter is 3.
    const gpa = std.testing.allocator;
    const ok = [_]u8{1};
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    {
        var script = Script{ .allocator = gpa };
        defer script.deinit();
        try script.push(.connect, 1, &.{3});
        try script.push(.printer_status_data, 16, &.{ 0x30, 0x30, 0x23, 0x28, 0x00, 0xc8, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x03, 0x01, 0x12, 0xee, 0x00 });
        try script.push(.set_label_type, 16, &ok);
        try script.push(.set_density, 16, &ok);
        try script.push(.start_print, 1, &ok);
        try script.push(.set_dimension, 1, &ok);
        try script.push(.end_page, 1, &ok);
        try script.pushPage(0, 0, 0);
        try script.pushPage(1, 100, 100);
        try script.pushPage(2, 40, 0);
        try script.pushPage(3, 100, 100);
        try script.push(.end_print, 1, &ok);
        var client = Client.init(gpa, scriptTransport(&script));
        defer client.deinit();
        client.d_series = true;
        client.copies = 3;
        try client.printGray(null, &pixels, 8, 1, 3);
        var frames = try framesWritten(gpa, script.written.items);
        defer frames.deinit(gpa);
        try std.testing.expectEqualSlices(u8, &.{ 0x01, 9, 0, 3, 0, 0, 0, 0, 0, 0, 0 }, frames.items[4]);
        try std.testing.expectEqualSlices(u8, &.{ 0x13, 13, 0, 1, 0, 8, 0, 3, 0, 0, 0, 0, 0, 0, 0 }, frames.items[6]);
        // Four status reads: the job waited past pages 1 and 2 for page 3.
        var polls: usize = 0;
        for (frames.items[7..]) |frame| {
            if (frame[0] == @backingInt(packet.Request.get_print_status)) polls += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), polls);
    }
    {
        var script = Script{ .allocator = gpa };
        defer script.deinit();
        try script.push(.connect, 1, &ok);
        try script.push(.set_density, 16, &ok);
        try script.push(.set_label_type, 16, &ok);
        try script.push(.start_print, 1, &ok);
        try script.push(.allow_print_clear, 16, &ok);
        try script.push(.start_page, 1, &ok);
        try script.push(.set_dimension, 1, &ok);
        try script.push(.set_quantity, 1, &ok);
        try script.push(.end_page, 1, &ok);
        try script.pushPage(0, 0, 0);
        try script.pushPage(3, 100, 100);
        try script.push(.end_print, 1, &ok);
        var client = Client.init(gpa, scriptTransport(&script));
        defer client.deinit();
        client.d_series = true;
        client.copies = 3;
        try client.printGray(null, &pixels, 8, 1, 3);
        var frames = try framesWritten(gpa, script.written.items);
        defer frames.deinit(gpa);
        var quantity: ?[]const u8 = null;
        for (frames.items) |frame| {
            if (frame[0] == @backingInt(packet.Request.set_quantity)) quantity = frame;
        }
        try std.testing.expectEqualSlices(u8, &.{ 0x15, 2, 0, 3 }, quantity orelse return error.NoQuantity);
    }
}

test "a second copy the job did not ask for is named in the trace" {
    // The counter reaches 1 while the head prints again at 5%: the printer is
    // on a second copy. This is what a D110_M did after idle before the job
    // set its copy count, and the trace said only "printed".
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(trace_mod.Trace.Entry, 16);
    defer gpa.free(entries);
    for (entries) |*entry| entry.* = .{};
    var trace = trace_mod.Trace{ .allocator = gpa, .entries = entries };

    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    // Protocol 0: the older D-series sequence, with clear and quantity.
    try script.push(.connect, 1, &ok);
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.allow_print_clear, 16, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.set_quantity, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushPage(0, 100, 100);
    try script.pushPage(1, 5, 0);
    try script.push(.end_print, 1, &ok);

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    client.trace = &trace;
    client.d_series = true;
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);

    try std.testing.expectEqualStrings("protocol 0", trace.at(0).messageText());
    try std.testing.expectEqualStrings("answers density=1 type=1 start=1 clear=1 page=1 dimension=1 quantity=1", trace.at(1).messageText());
    var warned = false;
    for (0..trace.held()) |i| {
        if (trace.at(i).level == .warn and std.mem.eql(u8, trace.at(i).messageText(), "page 1 done and another copy started")) warned = true;
    }
    try std.testing.expect(warned);
}

test "a page the printer never counts is not a successful print" {
    // The counter stays where it was after PageEnd, at 100%. That is an idle
    // printer answering "already finished". Ending there used to report success
    // and the label stayed in the machine.
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    for (0..Client.print_status_polls) |_| try script.pushPage(1, 100, 100);
    try script.push(.end_print, 1, &ok);

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try std.testing.expectError(error.PrintSkipped, client.printGray(null, &pixels, 8, 1, 3));

    var last: u8 = 0;
    var off: usize = 0;
    while (off < script.written.items.len) {
        const len = @as(usize, script.written.items[off + 3]) + 7;
        last = script.written.items[off + 2];
        off += len;
    }
    try std.testing.expectEqual(@backingInt(packet.Request.end_print), last);
}

test "progress that leaves 100 percent and returns counts as printed" {
    const gpa = std.testing.allocator;
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    const ok = [_]u8{1};
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    // Leftover "done" from the previous job, then this page, on the same index.
    try script.pushPage(1, 100, 100);
    try script.pushPage(1, 40, 10);
    try script.pushPage(1, 100, 100);
    try script.push(.end_print, 1, &ok);

    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);
}

test "a job refused after start_print still ends with end_print" {
    // SetPageSize answered with a print error (cover open, no paper): the
    // printer has started the job, so the client finishes it.
    const gpa = std.testing.allocator;
    const ok = [_]u8{1};
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    var wire: [packet.Packet.max_wire]u8 = undefined;
    try script.inbound.appendSlice(gpa, try (packet.Packet{ .packet_type = 0xDB, .data = &.{0x01} }).toBytes(&wire));
    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try std.testing.expectError(error.PrinterRefused, client.printGray(null, &pixels, 8, 1, 3));
    var frames = try framesWritten(gpa, script.written.items);
    defer frames.deinit(gpa);
    try std.testing.expectEqual(@backingInt(packet.Request.end_print), frames.items[frames.items.len - 1][0]);
}

test "a stray byte ahead of an answer is stepped over" {
    const gpa = std.testing.allocator;
    const ok = [_]u8{1};
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    try script.inbound.append(gpa, 0x00);
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushFinishedPage();
    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    try client.printGray(null, &pixels, 8, 1, 3);
}

test "a page counter at its top does not overflow" {
    const gpa = std.testing.allocator;
    const ok = [_]u8{1};
    var script = Script{ .allocator = gpa };
    defer script.deinit();
    try script.push(.set_density, 16, &ok);
    try script.push(.set_label_type, 16, &ok);
    try script.push(.start_print, 1, &ok);
    try script.push(.start_page, 1, &ok);
    try script.push(.set_dimension, 1, &ok);
    try script.push(.end_page, 1, &ok);
    try script.pushPage(0xFFFF, 100, 100);
    var client = Client.init(gpa, scriptTransport(&script));
    defer client.deinit();
    const pixels = [_]u8{ 0, 255, 0, 255, 0, 255, 0, 255 };
    // The counter never moves past its top here, so the job is not counted;
    // what matters is that the comparison does not stop the process.
    try std.testing.expectError(error.PrintSkipped, client.printGray(null, &pixels, 8, 1, 3));
}
