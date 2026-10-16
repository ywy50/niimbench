const std = @import("std");
const cordis = @import("cordis.zig");

/// A running log of what the process has been asked to do, kept in memory and
/// readable while it runs.
///
/// This exists because a printer is on the other end of a wire and the page is
/// in another process: when something looks wrong, the useful question is
/// "what did each side actually do", and the answer is not in a stack trace.
/// The server records its part here, the page posts its part to
/// `POST /api/trace`, and the whole thing reads back at `GET /api/trace`.
///
/// The ring is fixed size and never grows: a long-running process overwrites
/// its oldest entries instead of leaking, and a page that reports in a loop
/// cannot exhaust memory.
pub const Trace = struct {
    allocator: std.mem.Allocator,
    /// Present when the context was loaded by `loadDefault`. Without it a line
    /// still records, with a zero time.
    io: ?std.Io = null,
    /// The clock reading the trace opened at, so every line carries a relative
    /// time. Relative is what matters for "what happened first".
    started: std.Io.Timestamp = std.Io.Timestamp.zero,
    entries: []Entry,
    /// Index of the next entry to write.
    next: usize = 0,
    /// How many entries have ever been written, so a reader can say "oldest
    /// first" even after the ring has wrapped.
    written: usize = 0,

    pub const capacity = 256;
    pub const message_len = 320;
    pub const source_len = 24;

    pub const Entry = struct {
        /// Milliseconds since the trace started.
        at_ms: u64 = 0,
        /// Who said it: a plugin name, or `page` for the browser.
        source: [source_len]u8 = std.mem.zeroes([source_len]u8),
        source_len_used: usize = 0,
        level: Level = .info,
        message: [message_len]u8 = std.mem.zeroes([message_len]u8),
        message_len_used: usize = 0,

        pub fn sourceText(self: *const Entry) []const u8 {
            return self.source[0..self.source_len_used];
        }

        pub fn messageText(self: *const Entry) []const u8 {
            return self.message[0..self.message_len_used];
        }
    };

    pub const Level = enum {
        info,
        warn,
        err,

        pub fn text(self: Level) []const u8 {
            return switch (self) {
                .info => "info",
                .warn => "warn",
                .err => "error",
            };
        }
    };

    pub fn deinit(self: *Trace) void {
        self.allocator.free(self.entries);
        self.allocator.destroy(self);
    }

    /// Record one line. `message` is formatted into the fixed buffer and is
    /// truncated rather than refused: a dropped diagnostic is worse than a
    /// clipped one.
    pub fn log(self: *Trace, source: []const u8, level: Level, comptime format: []const u8, args: anytype) void {
        const entry = &self.entries[self.next];
        self.next = (self.next + 1) % self.entries.len;
        self.written += 1;

        if (self.io) |io| {
            const now = std.Io.Clock.awake.now(io);
            const elapsed: i64 = self.started.durationTo(now).toMilliseconds();
            entry.at_ms = @intCast(@max(elapsed, 0));
        } else {
            entry.at_ms = 0;
        }

        const source_used = @min(source.len, entry.source.len);
        @memcpy(entry.source[0..source_used], source[0..source_used]);
        entry.source_len_used = source_used;

        entry.level = level;
        const text = std.fmt.bufPrint(&entry.message, format, args) catch {
            // Too long for the line. `bufPrint` leaves the buffer untouched when
            // it cannot fit, and copying the format string instead put a bare
            // "{s}" in the log — a line that says nothing, and that reads like a
            // bug in the logger rather than a message that was too long. Render
            // into room of its own, keep the head, and mark where it was cut,
            // because the head is the part that says what happened.
            var room: [message_len * 4]u8 = undefined;
            const whole = std.fmt.bufPrint(&room, format, args) catch &room;
            const mark = "...[cut]";
            const keep = @min(whole.len, entry.message.len);
            if (keep == entry.message.len) {
                const tail = @min(mark.len, entry.message.len);
                @memcpy(entry.message[0 .. entry.message.len - tail], whole[0 .. entry.message.len - tail]);
                @memcpy(entry.message[entry.message.len - tail ..], mark[0..tail]);
            } else {
                @memcpy(entry.message[0..keep], whole[0..keep]);
            }
            entry.message_len_used = entry.message.len;
            return;
        };
        entry.message_len_used = text.len;
    }

    pub fn info(self: *Trace, source: []const u8, comptime format: []const u8, args: anytype) void {
        self.log(source, .info, format, args);
    }

    pub fn warn(self: *Trace, source: []const u8, comptime format: []const u8, args: anytype) void {
        self.log(source, .warn, format, args);
    }

    pub fn failure(self: *Trace, source: []const u8, comptime format: []const u8, args: anytype) void {
        self.log(source, .err, format, args);
    }

    /// The oldest entry still held, and how many are held. After the ring has
    /// wrapped the sequence is not contiguous in the array, so a reader walks it
    /// in two runs.
    pub fn oldest(self: *const Trace) usize {
        if (self.written <= self.entries.len) return 0;
        return self.next;
    }

    pub fn held(self: *const Trace) usize {
        return @min(self.written, self.entries.len);
    }

    /// Entry `i` of the log, oldest first.
    pub fn at(self: *const Trace, i: usize) *const Entry {
        return &self.entries[(self.oldest() + i) % self.entries.len];
    }
};

pub fn applyTrace(ctx: *cordis.Context) !void {
    const trace = try ctx.allocator.create(Trace);
    errdefer ctx.allocator.destroy(trace);
    const entries = try ctx.allocator.alloc(Trace.Entry, Trace.capacity);
    for (entries) |*entry| entry.* = .{};
    trace.* = .{ .allocator = ctx.allocator, .io = ctx.io, .entries = entries };
    if (ctx.io) |io| trace.started = std.Io.Clock.awake.now(io);
    try ctx.set("trace", trace, destroyTrace);
    trace.info("trace", "opened", .{});
}

fn destroyTrace(ptr: *anyopaque) void {
    const trace: *Trace = @ptrCast(@alignCast(ptr));
    trace.deinit();
}

test "the trace keeps the newest entries and reads them oldest first" {
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(Trace.Entry, 4);
    for (entries) |*entry| entry.* = .{};
    var trace = Trace{ .allocator = gpa, .entries = entries };
    defer gpa.free(entries);

    trace.info("server", "first {d}", .{1});
    trace.warn("page", "second", .{});
    trace.failure("printer", "third", .{});
    try std.testing.expectEqual(@as(usize, 3), trace.held());
    try std.testing.expectEqualStrings("first 1", trace.at(0).messageText());
    try std.testing.expectEqualStrings("page", trace.at(1).sourceText());
    try std.testing.expectEqual(Trace.Level.err, trace.at(2).level);

    // Overwrite the ring: the oldest falls off and the order still holds.
    trace.info("server", "fourth", .{});
    trace.info("server", "fifth", .{});
    try std.testing.expectEqual(@as(usize, 4), trace.held());
    try std.testing.expectEqualStrings("second", trace.at(0).messageText());
    try std.testing.expectEqualStrings("fifth", trace.at(3).messageText());
}

test "disposing the fiber removes the trace service" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    const fiber = try ctx.mount("trace", .{ .name = "trace", .apply = applyTrace });
    try std.testing.expect(ctx.get("trace") != null);
    fiber.dispose();
    try std.testing.expect(ctx.get("trace") == null);
}

test "a message too long for the line is clipped, not dropped" {
    const gpa = std.testing.allocator;
    const entries = try gpa.alloc(Trace.Entry, 2);
    for (entries) |*entry| entry.* = .{};
    var trace = Trace{ .allocator = gpa, .entries = entries };
    defer gpa.free(entries);

    var long: [Trace.message_len * 2]u8 = undefined;
    @memset(&long, 'x');
    trace.info("page", "{s}", .{long});
    try std.testing.expectEqual(@as(usize, 1), trace.held());
    try std.testing.expect(trace.at(0).messageText().len > 0);
    try std.testing.expect(trace.at(0).messageText().len <= Trace.message_len);
}
