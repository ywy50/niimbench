const std = @import("std");
const cordis = @import("cordis.zig");
const device = @import("device.zig");
const discovery = @import("discovery.zig");
const example_source = @import("example_source.zig");
const font = @import("font.zig");
const label = @import("label.zig");
const labels = @import("labels_catalogue.zig");
const trace_mod = @import("trace.zig");

/// Every `trace` call goes through here, because a context may have no trace
/// plugin (a test that mounts only what it needs). A missing log is not a
/// reason to fail a render.
fn tracer(service: *HttpService) ?*trace_mod.Trace {
    return service.trace;
}

const printer = @import("printer.zig");
const raster = @import("raster.zig");

pub const page_html = @embedFile("editor.html");

pub const Sources = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    bodies: std.ArrayList([]const u8) = .empty,

    /// Copy `name` and `json` into the registry. The caller keeps ownership of
    /// both slices.
    pub fn add(self: *Sources, name: []const u8, json: []const u8) !void {
        const held_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(held_name);
        try self.addOwned(held_name, try self.allocator.dupe(u8, json));
    }

    /// Take ownership of `name` and `json` until `remove`, which frees them.
    pub fn addOwned(self: *Sources, name: []const u8, json: []const u8) !void {
        errdefer self.allocator.free(name);
        errdefer self.allocator.free(json);
        try self.names.append(self.allocator, name);
        errdefer _ = self.names.pop();
        try self.bodies.append(self.allocator, json);
    }

    /// Take the record out of the registry and hand its strings to the caller,
    /// which frees them. Nothing else points at them, so this is also how a
    /// replace keeps the old record alive until the new one is in.
    pub fn remove(self: *Sources, name: []const u8) ?Entry {
        var i: usize = 0;
        while (i < self.names.items.len) : (i += 1) {
            if (!std.mem.eql(u8, self.names.items[i], name)) continue;
            return .{ .name = self.names.swapRemove(i), .body = self.bodies.swapRemove(i) };
        }
        return null;
    }

    /// The strings of one record, owned by whoever took them out.
    pub const Entry = struct {
        name: []const u8,
        body: []const u8,

        pub fn free(self: Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            allocator.free(self.name);
        }
    };

    pub fn find(self: Sources, name: []const u8) ?[]const u8 {
        for (self.names.items, self.bodies.items) |item, body| {
            if (std.mem.eql(u8, item, name)) return body;
        }
        return null;
    }
};

/// Records installed by `POST /api/sources`. They are process-scoped rather
/// than plugin-scoped, so the `http` fiber owns their lifetime: one effect
/// drops the whole set when that fiber goes away.
pub const RuntimeSources = struct {
    allocator: std.mem.Allocator,
    sources: *Sources,
    names: std.ArrayList([]const u8) = .empty,

    /// Install a record under its own name, replacing one of the same name if
    /// it exists. The returned entry is whatever the install displaced; the
    /// caller frees it once the new record is in place, so a failed install
    /// cannot leave a dangling record.
    pub fn install(self: *RuntimeSources, name: []const u8, json: []const u8) !?Sources.Entry {
        const held_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(held_name);
        const held_json = try self.allocator.dupe(u8, json);
        errdefer self.allocator.free(held_json);
        var displaced: ?Sources.Entry = null;
        if (self.take(name)) |index| {
            _ = self.names.swapRemove(index);
            displaced = self.sources.remove(name);
        }
        try self.sources.addOwned(held_name, held_json);
        errdefer if (self.sources.remove(name)) |entry| entry.free(self.allocator);
        try self.names.append(self.allocator, held_name);
        return displaced;
    }

    /// Forget the name this list tracked, returning where it sat. Dropping
    /// the tracked name is not the same as removing the record: this is also
    /// how a delete endpoint stops tracking a record it has already removed.
    fn take(self: *RuntimeSources, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.names.items.len) : (i += 1) {
            if (!std.mem.eql(u8, self.names.items[i], name)) continue;
            return i;
        }
        return null;
    }

    /// Remove a record this list owns. False means it was never installed here
    /// (a plugin owns it, or there is no such name).
    pub fn remove(self: *RuntimeSources, name: []const u8) bool {
        const index = self.take(name) orelse return false;
        _ = self.names.swapRemove(index);
        if (self.sources.remove(name)) |entry| entry.free(self.allocator);
        return true;
    }

    pub fn has(self: RuntimeSources, name: []const u8) bool {
        return self.take(name) != null;
    }

    pub fn clear(self: *RuntimeSources) void {
        for (self.names.items) |name| {
            if (self.sources.remove(name)) |entry| entry.free(self.allocator);
        }
        self.names.clearRetainingCapacity();
    }
};

fn dropRuntimeSources(ptr: *anyopaque) void {
    const runtime: *RuntimeSources = @ptrCast(@alignCast(ptr));
    runtime.clear();
    runtime.names.deinit(runtime.allocator);
    runtime.allocator.destroy(runtime);
}

/// A quarter turn of a whole page. Only the CLI uses this, for a raw PGM whose
/// pixels are the page: a label body turns its fields instead, because members
/// of a page each carry their own angle. A turn that is not a whole number of
/// quarter turns is `error.BadRotation`.
pub fn rotated(allocator: std.mem.Allocator, gray: raster.Gray, degrees: u16) !raster.Gray {
    return raster.rotate(allocator, gray.pixels, gray.width, gray.height, degrees);
}

pub const PrinterService = struct {
    allocator: std.mem.Allocator,

    pub fn submit(
        self: *PrinterService,
        io: ?std.Io,
        registry: device.Registry,
        allocator: std.mem.Allocator,
        model: raster.Model,
        conn: []const u8,
        addr: []const u8,
        pixels: []const u8,
        width: usize,
        height: usize,
        density: u8,
    ) !void {
        _ = self;
        // The page is printed as composed. A page is never turned here: the
        // only turn is a field's own `rotation`, which the renderer has already
        // applied, and turning again would turn the label itself.
        if (width > model.maxWidth()) return error.TooWide;
        var level = density;
        if (level > model.maxDensity()) level = model.maxDensity();
        // The beacon callers (the HTTP route and the CLI) always have an `Io`.
        // Only an in-process test may leave it out, and there the built-in
        // testing `Io` stands in.
        const live = io orelse if (@import("builtin").is_test) std.testing.io else unreachable;
        const transport = try registry.open(conn, allocator, live, addr);
        var client = printer.Client.init(allocator, transport);
        defer client.deinit();
        try client.printGray(io, pixels, width, height, level);
    }
};

pub const Handler = *const fn (*HttpService, RequestView) anyerror!Response;

pub const Route = struct {
    method: std.http.Method,
    path: []const u8,
    handler: Handler,
};

pub const RequestView = struct {
    io: std.Io,
    method: std.http.Method,
    path: []const u8,
    query: []const u8,
    body: []const u8,
    /// Raw `Cookie` header. Empty when the caller did not send one.
    cookie: []const u8 = "",
};

pub const Response = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/json",
    body: []const u8,
    owned: bool = false,
    /// `GET /?token=` sets the session cookie and redirects to `/`.
    set_cookie: bool = false,
    location: ?[]const u8 = null,
};

pub const HttpService = struct {
    allocator: std.mem.Allocator,
    ctx: *cordis.Context,
    host: []const u8,
    port: u16,
    token: [16]u8,
    token_hex: [32]u8,
    routes: std.ArrayList(Route) = .empty,
    printer: *PrinterService,
    transports: *device.Registry,
    devices: *discovery.Registry,
    sources: *Sources,
    runtime: *RuntimeSources,
    catalogue: labels.Catalogue,
    /// Absent unless the `trace` plugin is mounted.
    trace: ?*trace_mod.Trace = null,

    pub fn dispatch(self: *HttpService, req: RequestView) !Response {
        const from_query = queryValue(req.query, "token");
        const presented = from_query orelse cookieValue(req.cookie, "niimbench") orelse "";
        if (!std.mem.eql(u8, presented, &self.token_hex)) {
            return .{ .status = .unauthorized, .body = "{\"error\":\"bad token\"}" };
        }
        // The startup URL carries the token once. A browser that opens it
        // receives the cookie and is sent to `/`, so the address bar does not
        // keep the secret. Later requests send the cookie.
        if (from_query != null and req.method == .GET and std.mem.eql(u8, req.path, "/")) {
            return .{
                .status = .found,
                .content_type = "text/plain; charset=utf-8",
                .body = "",
                .set_cookie = true,
                .location = "/",
            };
        }
        // `/api/sources/<name>` is a prefix route rather than a handler in the
        // table, so it picks its own method. The token is checked before
        // anything looks at the name.
        if (std.mem.startsWith(u8, req.path, "/api/sources/")) {
            const name = req.path["/api/sources/".len..];
            return switch (req.method) {
                .GET => sourceRecord(self, name),
                .DELETE => deleteSource(self, name),
                else => .{ .status = .not_found, .body = "{\"error\":\"not found\"}" },
            };
        }
        for (self.routes.items) |route| {
            if (route.method == req.method and std.mem.eql(u8, route.path, req.path)) {
                return route.handler(self, req);
            }
        }
        return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
    }
};

const RouteState = struct {
    service: *HttpService,
    method: std.http.Method,
    path: []const u8,
};

fn unregisterRoute(state: *anyopaque) void {
    const mark: *RouteState = @ptrCast(@alignCast(state));
    var i: usize = 0;
    while (i < mark.service.routes.items.len) : (i += 1) {
        const route = mark.service.routes.items[i];
        if (route.method == mark.method and std.mem.eql(u8, route.path, mark.path)) {
            _ = mark.service.routes.swapRemove(i);
            break;
        }
    }
    mark.service.allocator.destroy(mark);
}

pub fn addRoute(service: *HttpService, method: std.http.Method, path: []const u8, handler: Handler) !void {
    const mark = try service.allocator.create(RouteState);
    mark.* = .{ .service = service, .method = method, .path = path };
    try service.ctx.effect(unregisterRoute, mark);
    try service.routes.append(service.allocator, .{ .method = method, .path = path, .handler = handler });
}

fn sourceRecord(service: *HttpService, name: []const u8) Response {
    const body = service.sources.find(name) orelse {
        return .{ .status = .not_found, .body = "{\"error\":\"unknown source\"}" };
    };
    return .{ .body = body };
}

pub fn health(_: *HttpService, _: RequestView) !Response {
    return .{ .body = "{\"ok\":true}" };
}

/// The editor page, with the session token written into it.
///
/// The page cannot read the token from its own URL: the boot is `GET /?token=`,
/// which redirects to `/`, so by the time the script runs the query is gone. It
/// then relied on the `HttpOnly` cookie, and a POST carrying a body had that
/// cookie dropped somewhere between the browser and here — the server answered
/// `bad token`, and an uploaded picture vanished with the preview cleared. The
/// token is injected instead, so every call the page makes can carry it in the
/// query and no request body can take it away.
pub fn page(service: *HttpService, _: RequestView) !Response {
    const marker = "%%NIIMBENCH_TOKEN%%";
    const at = std.mem.indexOf(u8, page_html, marker) orelse
        return .{ .content_type = "text/html; charset=utf-8", .body = page_html };
    const size = page_html.len - marker.len + service.token_hex.len;
    const body = try service.allocator.alloc(u8, size);
    @memcpy(body[0..at], page_html[0..at]);
    @memcpy(body[at..][0..service.token_hex.len], &service.token_hex);
    @memcpy(body[at + service.token_hex.len ..], page_html[at + marker.len ..]);
    return .{ .content_type = "text/html; charset=utf-8", .body = body, .owned = true };
}

pub fn listSources(service: *HttpService, _: RequestView) !Response {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(service.allocator);
    try buf.appendSlice(service.allocator, "{\"sources\":[");
    for (service.sources.names.items, 0..) |name, idx| {
        if (idx != 0) try buf.append(service.allocator, ',');
        try buf.append(service.allocator, '"');
        try buf.appendSlice(service.allocator, name);
        try buf.append(service.allocator, '"');
    }
    try buf.appendSlice(service.allocator, "]}");
    return .{ .body = try buf.toOwnedSlice(service.allocator), .owned = true };
}

pub fn listPorts(service: *HttpService, req: RequestView) !Response {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(service.allocator);
    try buf.append(service.allocator, '[');
    var dir = std.Io.Dir.openDirAbsolute(req.io, "/dev", .{ .iterate = true }) catch {
        try buf.append(service.allocator, ']');
        return .{ .body = try buf.toOwnedSlice(service.allocator), .owned = true };
    };
    defer dir.close(req.io);
    var it = dir.iterate();
    var first = true;
    while (try it.next(req.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "ttyACM") and !std.mem.startsWith(u8, entry.name, "ttyUSB")) continue;
        if (!first) try buf.append(service.allocator, ',');
        first = false;
        try buf.appendSlice(service.allocator, "\"/dev/");
        try buf.appendSlice(service.allocator, entry.name);
        try buf.append(service.allocator, '"');
    }
    try buf.append(service.allocator, ']');
    return .{ .body = try buf.toOwnedSlice(service.allocator), .owned = true };
}

const LabelRequest = struct {
    width: usize,
    height: usize,
    source: []const u8 = "",
    fields: []const label.Field = &.{},
    background_b64: []const u8 = "",
    density: u8 = 5,
    model: []const u8 = "b21",
    conn: []const u8 = "usb",
    addr: []const u8 = "",
    rotate: u16 = 0,
    pixels_b64: []const u8 = "",
};

pub fn printJob(service: *HttpService, req: RequestView) !Response {
    const size = requestSize(service.allocator, req.body);
    const parsed = std.json.parseFromSlice(LabelRequest, service.allocator, req.body, .{}) catch {
        return errorResponse(service.allocator, .bad_request, "bad json", size.width, size.height);
    };
    defer parsed.deinit();
    const job = parsed.value;
    const model = raster.Model.parse(job.model) catch {
        return errorResponse(service.allocator, .bad_request, "unknown model", job.width, job.height);
    };
    const gray = compose(service, job) catch |err| {
        if (tracer(service)) |t| t.failure("print", "compose {d}x{d} {s} model={s}: {s}", .{ job.width, job.height, job.conn, job.model, @errorName(err) });
        return composeError(service.allocator, err, size.width, size.height);
    };
    defer service.allocator.free(gray.pixels);
    if (tracer(service)) |t| t.info("print", "{d}x{d} dots, {d} field(s), density {d}, {s} {s}", .{
        gray.width, gray.height, job.fields.len, job.density, job.conn, job.addr,
    });
    service.printer.submit(
        req.io,
        service.transports.*,
        service.allocator,
        model,
        job.conn,
        job.addr,
        gray.pixels,
        gray.width,
        gray.height,
        job.density,
    ) catch |err| {
        if (tracer(service)) |t| t.failure("print", "failed: {s}", .{@errorName(err)});
        return errorResponse(service.allocator, .bad_request, @errorName(err), gray.width, gray.height);
    };
    if (tracer(service)) |t| t.info("print", "sent {d}x{d}", .{ gray.width, gray.height });
    service.ctx.emit("print/done");
    return .{ .body = "{\"ok\":true}" };
}

pub fn renderLabel(service: *HttpService, req: RequestView) !Response {
    const size = requestSize(service.allocator, req.body);
    const parsed = std.json.parseFromSlice(LabelRequest, service.allocator, req.body, .{}) catch {
        return errorResponse(service.allocator, .bad_request, "bad json", size.width, size.height);
    };
    defer parsed.deinit();
    _ = raster.Model.parse(parsed.value.model) catch {
        return errorResponse(service.allocator, .bad_request, "unknown model", parsed.value.width, parsed.value.height);
    };
    const composed = compose(service, parsed.value) catch |err| {
        return composeError(service.allocator, err, parsed.value.width, parsed.value.height);
    };
    defer service.allocator.free(composed.pixels);
    // The letters turn. The label does not: a 15 mm roll stays 96 dots across
    // the head, whichever way the word reads.
    const gray = composed;
    const encoded_len = std.base64.standard.Encoder.calcSize(gray.pixels.len);
    const body = try service.allocator.alloc(u8, 64 + encoded_len);
    errdefer service.allocator.free(body);
    const prefix = try std.fmt.bufPrint(body, "{{\"width\":{d},\"height\":{d},\"pixels_b64\":\"", .{
        gray.width, gray.height,
    });
    const encoded = std.base64.standard.Encoder.encode(body[prefix.len..], gray.pixels);
    const end = prefix.len + encoded.len;
    @memcpy(body[end..][0..2], "\"}");
    const used = end + 2;
    return .{ .body = try service.allocator.realloc(body, used), .owned = true };
}

/// The field list with every line placed by its alignment. `label.render` and
/// `label.renderOnto` draw where they are told, and the alignment needs the
/// resolved text width, so the arithmetic lives here, next to the resolution.
fn placedFields(allocator: std.mem.Allocator, job: LabelRequest, source_json: []const u8) ![]label.Field {
    if (job.fields.len == 0) return &.{};
    const out = try allocator.alloc(label.Field, job.fields.len);
    errdefer allocator.free(out);
    for (job.fields, 0..) |field, i| {
        out[i] = field;
        out[i].x = try label.alignedX(allocator, out[i], source_json);
        // The place is now in `x`, so the renderer must not apply the shift
        // again. This is the one and only place alignment is resolved.
        out[i].align_mode = .left;
    }
    return out;
}

fn compose(service: *HttpService, job: LabelRequest) !raster.Gray {
    // The page is printed as it is asked for. The margin that keeps the gap
    // sensor happy is taken off where a roll's size is resolved — see
    // `pxHeight` — so a caller asks for the page it wants and gets that page.
    // Subtracting it here as well would take it off twice.
    const height = job.height;
    const source_json = if (job.source.len == 0)
        ""
    else
        service.sources.find(job.source) orelse return error.UnknownSource;
    if (job.background_b64.len > 0) {
        const background = try decodeBackground(service.allocator, job.background_b64, job.width, job.height);
        if (job.fields.len == 0) {
            if (background.len != job.width * job.height) {
                service.allocator.free(background);
                return error.BadSize;
            }
            return .{ .pixels = background, .width = job.width, .height = job.height };
        }
        defer service.allocator.free(background);
        const placed = try placedFields(service.allocator, job, source_json);
        defer service.allocator.free(placed);
        return label.renderOnto(service.allocator, background, job.width, height, placed, source_json);
    }
    if (job.fields.len > 0) {
        const placed = try placedFields(service.allocator, job, source_json);
        defer service.allocator.free(placed);
        return label.render(service.allocator, job.width, height, placed, source_json);
    }
    if (job.pixels_b64.len == 0) return error.NothingToPrint;
    const pixels = try decodePixels(service.allocator, job.pixels_b64);
    if (pixels.len != job.width * job.height) {
        service.allocator.free(pixels);
        return error.BadSize;
    }
    return .{ .pixels = pixels, .width = job.width, .height = job.height };
}

/// A background arrives as one grayscale byte per pixel, or as one bit per
/// pixel, MSB first, rows packed back to back. The editor sends the bit form
/// because a label has one ink and a byte per pixel spends seven bits saying
/// nothing. The decoded length says which form it is, so both are accepted and
/// no request field has to change.
fn decodeBackground(allocator: std.mem.Allocator, encoded: []const u8, width: usize, height: usize) ![]u8 {
    const raw = try decodePixels(allocator, encoded);
    errdefer allocator.free(raw);
    if (raw.len == width * height) return raw;
    const row_bytes = raster.packedRowBytes(width);
    if (raw.len != row_bytes * height) return error.BadPixels;
    const pixels = try allocator.alloc(u8, width * height);
    errdefer allocator.free(pixels);
    for (0..height) |y| {
        const row = raw[y * row_bytes ..][0..row_bytes];
        for (0..width) |x| {
            const set = (row[x / 8] >> @intCast(7 - (x % 8))) & 1;
            pixels[y * width + x] = if (set == 1) 0 else 255;
        }
    }
    allocator.free(raw);
    return pixels;
}

test "a background decodes from bytes or from packed bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const width: usize = 8;
    const height: usize = 2;
    // The first pixel of each row is ink; the rest is paper.
    const gray = [_]u8{ 0, 255, 255, 255, 255, 255, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255 };
    const gray_b64 = std.base64.standard.Encoder.encode(
        allocator.alloc(u8, std.base64.standard.Encoder.calcSize(gray.len)) catch return error.OutOfMemory,
        &gray,
    );
    const from_gray = try decodeBackground(allocator, gray_b64, width, height);
    try std.testing.expectEqual(@as(usize, 16), from_gray.len);
    try std.testing.expectEqual(@as(u8, 0), from_gray[0]);
    try std.testing.expectEqual(@as(u8, 255), from_gray[1]);
    try std.testing.expectEqual(@as(u8, 0), from_gray[8]);

    // The same picture, one bit per pixel: a set bit is ink.
    const bits = [_]u8{ 0b10000000, 0b10000000 };
    const bits_b64 = std.base64.standard.Encoder.encode(
        allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bits.len)) catch return error.OutOfMemory,
        &bits,
    );
    const from_bits = try decodeBackground(allocator, bits_b64, width, height);
    try std.testing.expectEqualSlices(u8, from_gray, from_bits);

    // A length that is neither form is refused rather than guessed at.
    const wrong_b64 = std.base64.standard.Encoder.encode(
        allocator.alloc(u8, std.base64.standard.Encoder.calcSize(3)) catch return error.OutOfMemory,
        "abc",
    );
    try std.testing.expectError(error.BadPixels, decodeBackground(allocator, wrong_b64, width, height));
}

fn decodePixels(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.BadPixels;
    const pixels = try allocator.alloc(u8, len);
    errdefer allocator.free(pixels);
    std.base64.standard.Decoder.decode(pixels, encoded) catch return error.BadPixels;
    return pixels;
}

/// The editor draws selection boxes over the preview, and resizes them live
/// while a corner is dragged. It measures a line the way `font.lineWidth`
/// does — `ceil(units * size / line_units)`, where `units` sums the advances
/// of the line's code points — so it gets each font's own advance table
/// rather than a second copy of it in JavaScript. A code point a table lacks
/// draws that font's missing-glyph box, whose advance is `missing`.
///
/// `advances` is a list of runs, `[first, a0, a1, ...]`: the advance of code
/// point `first`, then of `first + 1`, and so on. Most of a font's map is
/// consecutive, so this is a fraction of the size of one pair per character.
pub fn labelMetrics(service: *HttpService, _: RequestView) !Response {
    const gpa = service.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{{\"default\":\"{s}\",\"max_size\":{d},\"fonts\":[", .{ font.default_id, label.max_size });
    const Runs = struct {
        out: *std.ArrayList(u8),
        gpa: std.mem.Allocator,
        last: ?u21 = null,
        fn visit(self: *@This(), codepoint: u21, units: u32) anyerror!void {
            if (self.last) |last| {
                if (codepoint == last + 1) {
                    try self.out.print(self.gpa, ",{d}", .{units});
                } else {
                    try self.out.print(self.gpa, "],[{d},{d}", .{ codepoint, units });
                }
            } else {
                try self.out.print(self.gpa, "[{d},{d}", .{ codepoint, units });
            }
            self.last = codepoint;
        }
    };
    for (&font.fonts, 0..) |*entry, i| {
        if (i != 0) try out.append(gpa, ',');
        try out.print(gpa, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"line_units\":{d},\"missing\":{d},\"advances\":[", .{
            entry.id, entry.name, entry.face.lineUnits(), entry.face.advance(0),
        });
        var runs = Runs{ .out = &out, .gpa = gpa };
        try entry.face.eachMapped(&runs, Runs.visit);
        if (runs.last != null) try out.append(gpa, ']');
        try out.appendSlice(gpa, "]}");
    }
    try out.appendSlice(gpa, "]}");
    return .{ .body = try out.toOwnedSlice(gpa), .owned = true };
}

/// Die-cut rolls per model, with the pixel width and height the editor should use.
/// Width is millimetres times 8, and it stops at that model's print head.
pub fn labelSizes(service: *HttpService, _: RequestView) !Response {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(service.allocator);
    try out.print(service.allocator, "{{\"dots_per_mm\":{d},\"models\":{{", .{raster.dots_per_mm});
    var first_model = true;
    inline for (@typeInfo(raster.Model).@"enum".field_names) |name| {
        const model = @field(raster.Model, name);
        if (!first_model) try out.append(service.allocator, ',');
        first_model = false;
        try out.print(service.allocator, "\"{s}\":{{\"max_width\":{d},\"default\":\"{s}\",\"sizes\":[", .{
            name, model.maxWidth(), raster.defaultLabelId(model),
        });
        var first_size = true;
        for (raster.label_sizes) |size| {
            if (!raster.sizeFits(size, model)) continue;
            const px = raster.sizePixels(size, model);
            if (!first_size) try out.append(service.allocator, ',');
            first_size = false;
            try out.print(service.allocator, "{{\"id\":\"{s}\",\"width_mm\":{d},\"height_mm\":{d},\"round\":{s},\"width\":{d},\"height\":{d}}}", .{
                size.id,
                size.width_mm,
                size.height_mm,
                if (size.round) "true" else "false",
                px.width,
                px.height,
            });
        }
        try out.appendSlice(service.allocator, "]}");
    }
    try out.appendSlice(service.allocator, "}}");
    return .{ .body = try out.toOwnedSlice(service.allocator), .owned = true };
}

/// The result of the last scan, in the shape the editor picks a printer from.
/// A device carries the connection and address to print with and the model the
/// print head implies, so picking one fills the whole printer row.
fn devicesBody(service: *HttpService) !Response {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(service.allocator);
    try out.appendSlice(service.allocator, "{\"scanned\":");
    try out.appendSlice(service.allocator, if (service.devices.scanned) "true" else "false");
    try out.appendSlice(service.allocator, ",\"devices\":[");
    for (service.devices.found.slice(), 0..) |*found, index| {
        if (index != 0) try out.append(service.allocator, ',');
        try out.appendSlice(service.allocator, "{\"conn\":\"");
        try out.appendSlice(service.allocator, found.conn.name());
        try out.appendSlice(service.allocator, "\",\"addr\":\"");
        try appendJsonString(&out, service.allocator, found.addr());
        try out.appendSlice(service.allocator, "\",\"name\":\"");
        try appendJsonString(&out, service.allocator, found.name());
        try out.appendSlice(service.allocator, "\",\"model\":");
        if (found.model) |model| {
            try out.print(service.allocator, "\"{s}\"", .{@tagName(model)});
        } else {
            try out.appendSlice(service.allocator, "null");
        }
        try out.appendSlice(service.allocator, ",\"model_id\":");
        try out.print(service.allocator, "{d}", .{found.model_id});
        try out.appendSlice(service.allocator, ",\"spp\":");
        try out.appendSlice(service.allocator, if (found.spp) "true" else "false");
        try out.append(service.allocator, '}');
    }
    try out.appendSlice(service.allocator, "]}");
    return .{ .body = try out.toOwnedSlice(service.allocator), .owned = true };
}

/// The scan result without asking the transports again. The editor reads this
/// on load and after a scan; the scan itself is `POST /api/devices/scan`.
pub fn listDevices(service: *HttpService, _: RequestView) !Response {
    return devicesBody(service);
}

/// Run the transports' scan and answer with what they found. `{"discover":true}`
/// asks the Bluetooth finder for an inquiry, which takes a couple of seconds;
/// without it the answer is the serial probe plus the devices BlueZ already
/// knows. A body that does not parse is the passive scan.
pub fn scanDevices(service: *HttpService, req: RequestView) !Response {
    const body = std.json.parseFromSlice(ScanBody, service.allocator, req.body, .{}) catch null;
    defer if (body) |parsed| parsed.deinit();
    const discover = if (body) |parsed| parsed.value.discover else false;
    service.devices.scan(req.io, service.allocator, discover);
    return devicesBody(service);
}

const ScanBody = struct {
    discover: bool = false,
};

const RollBody = struct {
    conn: []const u8,
    addr: []const u8,
    model: []const u8 = "b21",
    /// Off unless the caller asks. The catalogue compiled into the binary
    /// answers for every roll the vendor lists, so the cloud is only needed for
    /// a barcode outside that copy, and reaching it is the caller's choice.
    allow_cloud: bool = false,
};

/// The roll in the printer. The tag carries a barcode, not millimetres, so the
/// barcode is resolved here: [labels_catalogue.zig] holds every roll the vendor
/// lists, and the vendor's cloud is asked only when the caller opts in with
/// `allow_cloud`.
pub fn readRoll(service: *HttpService, req: RequestView) !Response {
    const parsed = std.json.parseFromSlice(RollBody, service.allocator, req.body, .{}) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad json\"}" };
    };
    defer parsed.deinit();
    if (parsed.value.addr.len == 0) return .{ .status = .bad_request, .body = "{\"error\":\"no address\"}" };
    const model = raster.Model.parse(parsed.value.model) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"unknown model\"}" };
    };
    const transport = service.transports.open(parsed.value.conn, service.allocator, req.io, parsed.value.addr) catch |err| {
        if (tracer(service)) |t| t.failure("roll", "{s} {s}: {s}", .{ parsed.value.conn, parsed.value.addr, @errorName(err) });
        return errorResponse(service.allocator, .bad_request, @errorName(err), 0, 0);
    };
    var client = printer.Client.init(service.allocator, transport);
    defer client.deinit();
    const barcode_owned = client.readBarcode() catch |err| {
        return errorResponse(service.allocator, .bad_request, @errorName(err), 0, 0);
    };
    const barcode = barcode_owned orelse {
        if (tracer(service)) |t| t.warn("roll", "no barcode from {s} {s}", .{ parsed.value.conn, parsed.value.addr });
        return .{ .status = .bad_request, .body = "{\"error\":\"no roll\"}" };
    };
    defer service.allocator.free(barcode);

    const mm = switch (rollSource(&service.catalogue, barcode, parsed.value.allow_cloud)) {
        .catalogue => |known| known,
        .cloud => lookupLabelMm(req.io, service.allocator, barcode) catch {
            return .{ .status = .bad_request, .body = "{\"error\":\"roll lookup failed\"}" };
        },
        .unknown => return .{ .status = .bad_request, .body = "{\"error\":\"unknown roll\"}" },
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(service.allocator);
    try out.print(service.allocator, "{{\"barcode\":\"{s}\",\"width_mm\":{d},\"height_mm\":{d},\"source\":\"{s}\",\"width\":{d},\"height\":{d},\"id\":", .{
        barcode, mm.width_mm, mm.height_mm, mm.source, pxWidth(model, mm), pxHeight(model, mm),
    });
    if (labelIdFor(model, mm.width_mm, mm.height_mm)) |found| {
        try out.print(service.allocator, "\"{s}\"", .{found});
    } else {
        try out.appendSlice(service.allocator, "null");
    }
    if (tracer(service)) |t| t.info("roll", "{s} -> {d}x{d} mm {d}x{d} dots from the {s}", .{
        barcode, mm.width_mm, mm.height_mm, pxWidth(model, mm), pxHeight(model, mm), mm.source,
    });
    try out.append(service.allocator, '}');
    return .{ .body = try out.toOwnedSlice(service.allocator), .owned = true };
}

/// The canvas a roll implies for this head, in dots. A known roll's preset
/// already has its width clamped to the head, and an unknown one is scaled and
/// clamped here.
/// The roll's own width in dots, clamped to the head.
fn pxWidth(model: raster.Model, mm: labelLookup) usize {
    if (labelIdFor(model, mm.width_mm, mm.height_mm)) |id| return raster.sizePixels(raster.findLabelSize(id).?, model).width;
    return @min(@as(usize, mm.width_mm) * raster.dots_per_mm, model.maxWidth());
}

/// The height the caller should lay out on: the roll less the model's page
/// margin. This is the one place the margin is taken off. `compose` prints the
/// page it is asked for, so the page's own size is what it draws, and a preview
/// is the same frame as the print.
///
/// The page and the roll are different numbers, and mixing them is how a
/// negative box coordinate happens: a 12x40 roll is 320 dots tall, the page on
/// it is 304, and a caller that lays out against 320 builds a view taller than
/// the picture.
fn pxHeight(model: raster.Model, mm: labelLookup) usize {
    const roll = if (labelIdFor(model, mm.width_mm, mm.height_mm)) |id|
        raster.sizePixels(raster.findLabelSize(id).?, model).height
    else
        @as(usize, mm.height_mm) * raster.dots_per_mm;
    return roll -| model.pageMargin();
}

/// Where a barcode is resolved. The catalogue compiled into the binary is the
/// default and needs nothing from the caller: it holds every roll the vendor
/// lists, so a request for one of those never touches the network. Only a
/// barcode the catalogue does not carry can go further, and only when the
/// caller has opted in with `allow_cloud`.
const RollSource = union(enum) {
    catalogue: labelLookup,
    cloud,
    unknown,
};

fn rollSource(catalogue: *const labels.Catalogue, barcode: []const u8, allow_cloud: bool) RollSource {
    if (catalogue.find(barcode)) |known| {
        return .{ .catalogue = .{
            .width_mm = known.width_mm,
            .height_mm = known.height_mm,
            .source = "catalogue",
        } };
    }
    return if (allow_cloud) .cloud else .unknown;
}

/// The whole trace, oldest first, as plain text: one line per event, easy to
/// read with `curl` and easy to paste into a report. `?clear=1` empties it
/// first, which is how a run is bounded.
pub fn traceText(service: *HttpService, req: RequestView) !Response {
    const trace = tracer(service) orelse return .{ .status = .not_found, .body = "{\"error\":\"no trace plugin\"}" };
    if (queryValue(req.query, "clear") != null) {
        for (trace.entries) |*entry| entry.* = .{};
        trace.next = 0;
        trace.written = 0;
        trace.info("trace", "cleared", .{});
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(service.allocator);
    for (0..trace.held()) |i| {
        const entry = trace.at(i);
        try out.print(service.allocator, "{d:>7}ms {s:<7} {s:<9} {s}\n", .{
            entry.at_ms,
            entry.level.text(),
            entry.sourceText(),
            entry.messageText(),
        });
    }
    return .{ .content_type = "text/plain; charset=utf-8", .body = try out.toOwnedSlice(service.allocator), .owned = true };
}

/// A line from the page. The body is `{"level":"...","source":"...","message":"..."}`
/// and every field is optional; the page is the only writer.
pub fn tracePost(service: *HttpService, req: RequestView) !Response {
    const trace = tracer(service) orelse return .{ .status = .not_found, .body = "{\"error\":\"no trace plugin\"}" };
    const Line = struct {
        level: []const u8 = "info",
        source: []const u8 = "page",
        message: []const u8 = "",
    };
    const parsed = std.json.parseFromSlice(Line, service.allocator, req.body, .{ .ignore_unknown_fields = true }) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad json\"}" };
    };
    defer parsed.deinit();
    const level: trace_mod.Trace.Level = if (std.mem.eql(u8, parsed.value.level, "error"))
        .err
    else if (std.mem.eql(u8, parsed.value.level, "warn"))
        .warn
    else
        .info;
    trace.log(parsed.value.source, level, "{s}", .{parsed.value.message});
    return .{ .body = "{\"ok\":true}" };
}

fn labelIdFor(model: raster.Model, width_mm: u16, height_mm: u16) ?[]const u8 {
    for (raster.label_sizes) |size| {
        if (size.round) continue;
        if (size.width_mm == width_mm and size.height_mm == height_mm and raster.sizeFits(size, model)) return size.id;
    }
    return null;
}

fn jsonUint(body: []const u8, key: []const u8) ?u16 {
    const at = std.mem.indexOf(u8, body, key) orelse return null;
    var i = at + key.len;
    while (i < body.len and body[i] == ' ') i += 1;
    var n: u32 = 0;
    var any = false;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {
        any = true;
        n = n * 10 + (body[i] - '0');
        if (n > 1000) return null;
    }
    if (!any) return null;
    return @intCast(n);
}

const labelLookup = struct { width_mm: u16, height_mm: u16, source: []const u8 };

fn lookupLabelMm(io: std.Io, allocator: std.mem.Allocator, barcode: []const u8) !labelLookup {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    const payload = try std.fmt.allocPrint(allocator, "{{\"oneCode\":\"{s}\"}}", .{barcode});
    defer allocator.free(payload);
    const result = try client.fetch(.{
        .location = .{ .url = "https://print.niimbot.com/api/template/getCloudTemplateByOneCode" },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "niimbot-user-agent", .value = "AppVersionName/5.0.0" },
        },
        .response_writer = &sink.writer,
    });
    if (result.status != .ok) return error.LookupFailed;
    return .{
        .width_mm = jsonUint(sink.written(), "\"width\":") orelse return error.LookupFailed,
        .height_mm = jsonUint(sink.written(), "\"height\":") orelse return error.LookupFailed,
        .source = "cloud",
    };
}

/// A found name and address come from a device and land in JSON, so a quote or
/// a control byte must be escaped instead of ending the string.
fn appendJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            else => {
                if (c < 0x20) {
                    try out.print(allocator, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
}

const SourceBody = struct {
    name: []const u8,
    json: []const u8,
};

/// Record a name the editor may use as a JSON identifier, in the registry and
/// in the page. A name with a quote or a backslash would either break the
/// response or the script, so it is rejected at install time.
fn validSourceName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (c == '/' or c == '"' or c == '\\') return false;
        if (c < 0x20) return false;
    }
    return true;
}

/// `POST /api/sources` installs a record that lives until the `http` fiber is
/// disposed. The example source is a plugin instead, because it is part of the
/// boot list; this route is for records that arrive while the process runs.
/// A name that already exists is replaced, and the answer says so.
pub fn installSource(service: *HttpService, req: RequestView) !Response {
    const parsed = std.json.parseFromSlice(SourceBody, service.allocator, req.body, .{}) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad json\"}" };
    };
    defer parsed.deinit();
    if (!validSourceName(parsed.value.name)) {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad name\"}" };
    }
    requireJsonObject(service.allocator, parsed.value.json) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"source must be a json object\"}" };
    };
    const displaced = try service.runtime.install(parsed.value.name, parsed.value.json);
    defer if (displaced) |entry| entry.free(service.allocator);
    return .{ .body = if (displaced != null) "{\"ok\":true,\"replaced\":true}" else "{\"ok\":true}" };
}

/// `DELETE /api/sources/<name>` drops a record this process installed at
/// runtime. A record a plugin owns is not removable from here: the plugin's
/// fiber is what owns its lifetime. The answer distinguishes the two cases, so
/// the page can say which one it hit.
pub fn deleteSource(service: *HttpService, name: []const u8) Response {
    if (service.runtime.remove(name)) return .{ .body = "{\"ok\":true}" };
    if (service.sources.find(name) != null) {
        return .{ .status = .bad_request, .body = "{\"error\":\"source belongs to a plugin\"}" };
    }
    return .{ .status = .not_found, .body = "{\"error\":\"unknown source\"}" };
}

/// The names `DELETE` accepts, in the same shape as `/api/sources`.
pub fn listRuntimeSources(service: *HttpService, _: RequestView) !Response {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(service.allocator);
    try buf.appendSlice(service.allocator, "{\"sources\":[");
    for (service.runtime.names.items, 0..) |name, idx| {
        if (idx != 0) try buf.append(service.allocator, ',');
        try buf.append(service.allocator, '"');
        try buf.appendSlice(service.allocator, name);
        try buf.append(service.allocator, '"');
    }
    try buf.appendSlice(service.allocator, "]}");
    return .{ .body = try buf.toOwnedSlice(service.allocator), .owned = true };
}

/// Which record a field reads, and the text it ends up drawing.
const TrackBody = struct {
    source: []const u8 = "",
    fields: []const label.Field = &.{},
};

/// The render routes report ink, not provenance. The editor wants to say which
/// fields draw a value from the selected record and to show that value, and a
/// legend built from client-side guesses drifts from what the renderer did.
/// This route answers with the same resolution `label.resolve` performs.
/// What one field draws and where that line starts. `x` is after alignment,
/// so the editor's selection box matches the ink the server will lay down.
const Tracked = struct {
    origin: []const u8,
    /// Points into the caller's arena, or is owned when `owned` is set.
    text: []const u8 = "",
    owned: ?[]u8 = null,
    x: usize,
};

fn trackField(service: *HttpService, job: TrackBody, field: label.Field) !Tracked {
    // A field with no key draws its own literal text. It still has to be
    // measured, or the editor's box would sit on the anchor instead of on the
    // aligned line.
    if (field.key.len == 0) {
        const x = try label.alignedX(service.allocator, field, "");
        return .{ .origin = "literal", .text = field.text, .x = x };
    }
    const record = if (job.source.len == 0) null else service.sources.find(job.source);
    const from_record = if (record) |body| try recordValue(service.allocator, body, field.key) else .missing;
    // The record answer is a fresh allocation that the caller must free; a key
    // that did not resolve carries no text.
    var owned: ?[]u8 = null;
    errdefer if (owned) |text| service.allocator.free(text);
    const resolved: []const u8 = switch (from_record) {
        .value => |held| blk: {
            owned = held;
            break :blk held;
        },
        .structured => {
            return .{ .origin = "structured", .x = try label.alignedX(service.allocator, field, "") };
        },
        .dynamic => {
            return .{ .origin = "dynamic", .x = try label.alignedX(service.allocator, field, "") };
        },
        .missing => "",
    };
    const origin: []const u8 = switch (from_record) {
        .value => "record",
        .missing => if (record == null) "unknown-source" else "missing-key",
        else => unreachable,
    };
    // The measured line is the value the record holds, which replaces the
    // field's own text, so the position comes from that text and this mode.
    const x = try label.alignedX(service.allocator, fieldWithText(field, resolved), "");
    return .{ .origin = origin, .text = resolved, .owned = owned, .x = x };
}

/// The same field with its `key` replaced by the text that key resolved to, so
/// `label.alignedX` measures exactly what will be drawn.
fn fieldWithText(field: label.Field, text: []const u8) label.Field {
    var out = field;
    out.key = "";
    out.text = text;
    return out;
}

const RecordValue = union(enum) {
    /// Owned by the caller.
    value: []u8,
    structured,
    dynamic,
    missing,
};

/// The text a field draws from `record`, plus why it does not when it does not.
fn recordValue(allocator: std.mem.Allocator, record: []const u8, key: []const u8) !RecordValue {
    if (key.len == 0) return .missing;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, record, .{}) catch return .dynamic;
    defer parsed.deinit();
    if (parsed.value != .object) return .structured;
    const held = parsed.value.object.get(key) orelse return .missing;
    // A number or a bool is formatted into its own allocation, which is
    // temporary; a string points into the parse arena. The answer is a copy of
    // whichever it is, because the arena goes away when this function returns.
    const formatted = switch (held) {
        .integer, .float, .bool => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(held, .{})}),
        else => null,
    };
    defer if (formatted) |text| allocator.free(text);
    const text = switch (held) {
        .string => |text| text,
        .number_string => |text| text,
        .integer, .float, .bool => formatted.?,
        else => return .structured,
    };
    if (!plainText(text)) return .dynamic;
    return .{ .value = try allocator.dupe(u8, text) };
}

pub fn trackFields(service: *HttpService, req: RequestView) !Response {
    const parsed = std.json.parseFromSlice(TrackBody, service.allocator, req.body, .{}) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad json\"}" };
    };
    defer parsed.deinit();
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(service.allocator);
    try buf.appendSlice(service.allocator, "{\"fields\":[");
    for (parsed.value.fields, 0..) |field, idx| {
        if (idx != 0) try buf.append(service.allocator, ',');
        // Scoped so the tracked text is freed per field. A `defer` written
        // directly in the loop body would only run when the function returns.
        const entry = entry: {
            // A field the renderer would refuse — an unknown font — is refused
            // here too, by name, rather than failing the whole route.
            const tracked = trackField(service, parsed.value, field) catch |err| {
                buf.deinit(service.allocator);
                return errorResponse(service.allocator, .bad_request, @errorName(err), 0, 0);
            };
            errdefer if (tracked.owned) |owned| service.allocator.free(owned);
            break :entry tracked;
        };
        defer if (entry.owned) |owned| service.allocator.free(owned);
        try buf.appendSlice(service.allocator, "{\"origin\":\"");
        try buf.appendSlice(service.allocator, entry.origin);
        try buf.append(service.allocator, '"');
        if (entry.text.len > 0) {
            try buf.appendSlice(service.allocator, ",\"text\":\"");
            try appendJsonString(&buf, service.allocator, entry.text);
            try buf.append(service.allocator, '"');
        }
        try buf.appendSlice(service.allocator, ",\"x\":");
        var number: [24]u8 = undefined;
        try buf.appendSlice(service.allocator, try std.fmt.bufPrint(&number, "{d}", .{entry.x}));
        try buf.append(service.allocator, '}');
    }
    try buf.appendSlice(service.allocator, "]}");
    return .{ .body = try buf.toOwnedSlice(service.allocator), .owned = true };
}

/// A record body is written into a JSON string here, so it may not carry a
/// quote, a backslash, or a control byte that would need escaping. The editor's
/// own records are plain text; a body that is not is reported as `dynamic`
/// instead of being escaped into the answer.
fn plainText(text: []const u8) bool {
    for (text) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

/// A failed render answers in the same shape as a successful one, with the
/// label size the client asked for. The editor can then draw an empty label
/// instead of leaving a stale preview on screen.
fn errorResponse(allocator: std.mem.Allocator, status: std.http.Status, name: []const u8, width: usize, height: usize) !Response {
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\",\"width\":{d},\"height\":{d}}}", .{
        name, width, height,
    });
    return .{ .status = status, .body = body, .owned = true };
}

fn composeError(allocator: std.mem.Allocator, err: anyerror, width: usize, height: usize) !Response {
    const status: std.http.Status = if (err == error.UnknownSource) .not_found else .bad_request;
    return errorResponse(allocator, status, @errorName(err), width, height);
}

/// The editor always sends `width` and `height`, but a hand-written body may
/// not. Only a body that does not parse as JSON at all loses the size.
const default_label_width = 384;
const default_label_height = 96;

const LabelSize = struct { width: usize, height: usize };

fn requestSize(allocator: std.mem.Allocator, body: []const u8) LabelSize {
    const Sizes = struct { width: ?usize = null, height: ?usize = null };
    const parsed = std.json.parseFromSlice(Sizes, allocator, body, .{}) catch {
        return .{ .width = default_label_width, .height = default_label_height };
    };
    defer parsed.deinit();
    return .{
        .width = parsed.value.width orelse default_label_width,
        .height = parsed.value.height orelse default_label_height,
    };
}

/// A source body must be a JSON object, because `label.Field.key` reads one
/// property out of a flat record. Anything else would only ever draw blanks.
pub fn requireJsonObject(allocator: std.mem.Allocator, json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.BadJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadJson;
}

pub fn serve(service: *HttpService, io: std.Io, open_browser: bool) !void {
    const address = try std.Io.net.IpAddress.parse(service.host, service.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://{s}:{d}/?token={s}\n", .{
        service.host, port, service.token_hex,
    });
    var stdout_buffer: [256]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    try stdout_file.interface.writeAll(url);
    try stdout_file.interface.flush();
    if (open_browser) openBrowser(io, url[0 .. url.len - 1]);

    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.err("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        handle(service, io, stream);
    }
}

fn handle(service: *HttpService, io: std.Io, stream: std.Io.net.Stream) void {
    defer stream.close(io);
    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var request = http_server.receiveHead() catch return;

    var target_buf: [1024]u8 = undefined;
    const target_len = @min(request.head.target.len, target_buf.len);
    @memcpy(target_buf[0..target_len], request.head.target[0..target_len]);
    const target = target_buf[0..target_len];
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |at| target[0..at] else target;
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |at| target[at + 1 ..] else "";

    // Read the cookie before the body. `iterateHeaders` asserts that the head
    // is still the current read state, and consuming a body moves the reader
    // past it, which would abort the process on any request that carries one.
    const cookie = headerValue(&request, "cookie");

    var body: []u8 = &.{};
    defer if (body.len != 0) service.allocator.free(body);
    // A method that may carry a body does not have to: curl sends `PUT` with
    // no content-length, and reading to end-of-stream would wait forever. Only
    // read when the head announced bytes.
    const announced = if (request.head.content_length) |length| length != 0 else false;
    if (request.head.method.requestHasBody() and announced) {
        var scratch: [4096]u8 = undefined;
        const reader = request.readerExpectNone(&scratch);
        body = reader.allocRemaining(service.allocator, .limited(4 << 20)) catch {
            return;
        };
    }

    const response = service.dispatch(.{
        .io = io,
        .method = request.head.method,
        .path = path,
        .query = query,
        .body = body,
        .cookie = cookie,
    }) catch |err| Response{
        .status = .internal_server_error,
        .body = @errorName(err),
    };
    defer if (response.owned) service.allocator.free(response.body);

    var cookie_buf: [80]u8 = undefined;
    const cookie_header = std.fmt.bufPrint(&cookie_buf, "niimbench={s}; HttpOnly; Path=/; SameSite=Strict", .{&service.token_hex}) catch return;

    var headers: [4]std.http.Header = undefined;
    var count: usize = 0;
    headers[count] = .{ .name = "content-type", .value = response.content_type };
    count += 1;
    headers[count] = .{ .name = "cache-control", .value = "no-store" };
    count += 1;
    if (response.set_cookie) {
        headers[count] = .{ .name = "set-cookie", .value = cookie_header };
        count += 1;
    }
    if (response.location) |location| {
        headers[count] = .{ .name = "location", .value = location };
        count += 1;
    }

    request.respond(response.body, .{
        .status = response.status,
        .keep_alive = false,
        .extra_headers = headers[0..count],
    }) catch {};
}

fn headerValue(request: *std.http.Server.Request, name: []const u8) []const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return "";
}

fn cookieValue(header: []const u8, name: []const u8) ?[]const u8 {
    var rest = header;
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == ';')) rest = rest[1..];
        if (rest.len == 0) break;
        const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const part = std.mem.trim(u8, rest[0..end], " ");
        if (std.mem.startsWith(u8, part, name) and part.len > name.len and part[name.len] == '=') {
            return part[name.len + 1 ..];
        }
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
    }
    return null;
}

fn queryValue(query: []const u8, name: []const u8) ?[]const u8 {
    var rest = query;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const part = rest[0..amp];
        if (std.mem.startsWith(u8, part, name) and part.len > name.len and part[name.len] == '=') {
            return part[name.len + 1 ..];
        }
        if (amp == rest.len) break;
        rest = rest[amp + 1 ..];
    }
    return null;
}

fn openBrowser(io: std.Io, url: []const u8) void {
    const future = io.concurrent(openBrowserTask, .{ io, url }) catch return;
    _ = future;
}

fn openBrowserTask(io: std.Io, url: []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "xdg-open", url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn fillToken(service: *HttpService) !void {
    const rc = std.os.linux.getrandom(&service.token, service.token.len, 0);
    const signed: isize = @bitCast(rc);
    if (signed != service.token.len) return error.NoRandom;
    const hex = "0123456789abcdef";
    for (service.token, 0..) |byte, i| {
        service.token_hex[i * 2] = hex[byte >> 4];
        service.token_hex[i * 2 + 1] = hex[byte & 0x0F];
    }
}

pub fn create(
    ctx: *cordis.Context,
    printer_service: *PrinterService,
    transports: *device.Registry,
    devices: *discovery.Registry,
    sources: *Sources,
    runtime: *RuntimeSources,
    catalogue: labels.Catalogue,
    trace: ?*trace_mod.Trace,
) !*HttpService {
    const service = try ctx.allocator.create(HttpService);
    service.* = .{
        .allocator = ctx.allocator,
        .ctx = ctx,
        .host = ctx.http_host,
        .port = ctx.http_port,
        .token = undefined,
        .token_hex = undefined,
        .printer = printer_service,
        .transports = transports,
        .devices = devices,
        .sources = sources,
        .runtime = runtime,
        .catalogue = catalogue,
        .trace = trace,
    };
    try fillToken(service);
    return service;
}

fn destroyHttp(ptr: *anyopaque) void {
    const service: *HttpService = @ptrCast(@alignCast(ptr));
    service.routes.deinit(service.allocator);
    service.catalogue.deinit();
    service.allocator.destroy(service);
}

pub fn applyHttp(ctx: *cordis.Context) !void {
    const printer_service = ctx.require(PrinterService, "printer");
    const transports = ctx.require(device.Registry, "transports");
    const devices = ctx.require(discovery.Registry, "devices");
    const sources = ctx.require(Sources, "sources");
    // Optional: a context that mounts only `http` still serves every route, it
    // just has nowhere to record what happened.
    const trace: ?*trace_mod.Trace = if (ctx.get("trace")) |raw| @ptrCast(@alignCast(raw)) else null;
    const runtime = try ctx.allocator.create(RuntimeSources);
    errdefer ctx.allocator.destroy(runtime);
    runtime.* = .{ .allocator = ctx.allocator, .sources = sources };
    try ctx.effect(dropRuntimeSources, runtime);
    // The label catalogue is compiled in, so a roll's barcode resolves without
    // a network round trip. It is parsed once and lives as long as the service.
    var catalogue = try labels.load(ctx.allocator);
    errdefer catalogue.deinit();
    const service = try create(ctx, printer_service, transports, devices, sources, runtime, catalogue, trace);
    try ctx.set("http", service, destroyHttp);
    try addRoute(service, .GET, "/api/health", health);
    try addRoute(service, .GET, "/api/ports", listPorts);
    try addRoute(service, .GET, "/api/devices", listDevices);
    try addRoute(service, .POST, "/api/devices/scan", scanDevices);
    try addRoute(service, .GET, "/api/sources", listSources);
    try addRoute(service, .POST, "/api/sources", installSource);
    try addRoute(service, .GET, "/api/runtime-sources", listRuntimeSources);
    try addRoute(service, .GET, "/api/label/metrics", labelMetrics);
    try addRoute(service, .GET, "/api/label/sizes", labelSizes);
    try addRoute(service, .POST, "/api/label/track", trackFields);
    try addRoute(service, .POST, "/api/render", renderLabel);
    try addRoute(service, .POST, "/api/print", printJob);
    try addRoute(service, .POST, "/api/label/roll", readRoll);
    try addRoute(service, .GET, "/api/trace", traceText);
    try addRoute(service, .POST, "/api/trace", tracePost);
}

pub fn applyEditor(ctx: *cordis.Context) !void {
    const service = ctx.require(HttpService, "http");
    try addRoute(service, .GET, "/", page);
}

pub fn hasRoute(http: *HttpService, method: std.http.Method, path: []const u8) bool {
    for (http.routes.items) |route| {
        if (route.method == method and std.mem.eql(u8, route.path, path)) return true;
    }
    return false;
}

pub fn applyTransports(ctx: *cordis.Context) !void {
    const box = try ctx.allocator.create(RegistryBox);
    box.* = .{ .allocator = ctx.allocator };
    try ctx.set("transports", &box.registry, destroyRegistryBox);
}

const RegistryBox = struct {
    allocator: std.mem.Allocator,
    registry: device.Registry = .{},
};

fn destroyRegistryBox(ptr: *anyopaque) void {
    const registry: *device.Registry = @ptrCast(@alignCast(ptr));
    const box: *RegistryBox = @fieldParentPtr("registry", registry);
    const allocator = box.allocator;
    allocator.destroy(box);
}

/// The `devices` plugin publishes where a scan finds printers. `serial` and
/// `bluetooth` install their finders into it; disposing either plugin takes its
/// finder back out, and the last scan stays as the answer until the next one.
pub fn applyDevices(ctx: *cordis.Context) !void {
    const box = try ctx.allocator.create(DevicesBox);
    box.* = .{ .allocator = ctx.allocator };
    try ctx.set("devices", &box.registry, destroyDevicesBox);
}

const DevicesBox = struct {
    allocator: std.mem.Allocator,
    registry: discovery.Registry = .{},
};

fn destroyDevicesBox(ptr: *anyopaque) void {
    const registry: *discovery.Registry = @ptrCast(@alignCast(ptr));
    const box: *DevicesBox = @fieldParentPtr("registry", registry);
    const allocator = box.allocator;
    allocator.destroy(box);
}

pub fn applySources(ctx: *cordis.Context) !void {
    const sources = try ctx.allocator.create(Sources);
    sources.* = .{ .allocator = ctx.allocator };
    try ctx.set("sources", sources, destroySources);
}

fn destroySources(ptr: *anyopaque) void {
    const sources: *Sources = @ptrCast(@alignCast(ptr));
    for (sources.names.items) |name| sources.allocator.free(name);
    for (sources.bodies.items) |body| sources.allocator.free(body);
    sources.names.deinit(sources.allocator);
    sources.bodies.deinit(sources.allocator);
    sources.allocator.destroy(sources);
}

pub fn applyPrinter(ctx: *cordis.Context) !void {
    const service = try ctx.allocator.create(PrinterService);
    service.* = .{ .allocator = ctx.allocator };
    try ctx.set("printer", service, destroyPrinter);
}

fn destroyPrinter(ptr: *anyopaque) void {
    const service: *PrinterService = @ptrCast(@alignCast(ptr));
    service.allocator.destroy(service);
}

fn mountHttp(ctx: *cordis.Context) !void {
    _ = try mountHttpFiber(ctx);
}

/// Same boot list as `mountHttp`, but hands back the `http` fiber so a test can
/// dispose exactly that plugin instead of guessing an index.
fn mountHttpFiber(ctx: *cordis.Context) !*cordis.Fiber {
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = applySources });
    return ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "devices", "sources" },
        .apply = applyHttp,
    });
}

/// The boot list plus the plugin-owned record, for tests about the two source
/// lifetimes meeting at one route.
fn mountHttpWithExample(ctx: *cordis.Context) !*cordis.Fiber {
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = applyTransports });
    _ = try ctx.mount("devices", .{ .name = "devices", .apply = applyDevices });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = applySources });
    _ = try ctx.mount("json-source", .{
        .name = "json-source",
        .inject = &.{"sources"},
        .apply = example_source.applyExampleSource,
    });
    return ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "devices", "sources" },
        .apply = applyHttp,
    });
}

test "the editor route disappears when its fiber is disposed" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const editor = try ctx.mount("editor", .{ .name = "editor", .inject = &.{"http"}, .apply = applyEditor });
    const http = ctx.require(HttpService, "http");
    try std.testing.expect(hasRoute(http, .GET, "/"));
    editor.dispose();
    try std.testing.expect(!hasRoute(http, .GET, "/"));
}

test "editor page renders fields through the server" {
    // The page as it is used: a label editor with a printer, not the record
    // feature. The source-record controls are deliberately not here.
    const control = [_][]const u8{ "save", "load", "reset", "add-field", "device", "scan-devices", "upright" };

    try std.testing.expect(std.mem.indexOf(u8, page_html, "/api/render") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "field-list") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "id=\"snap\"") != null);
    // Turning text: the Orientation pair is a starting point for a new field,
    // every field carries its own degrees, and a field can be dragged round.
    try std.testing.expect(std.mem.indexOf(u8, page_html, "data-rotate=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "data-rotate=\"90\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "rotation.className = \"degrees\"") != null);
    // The degrees a field is turned to travel to the renderer with the field,
    // and nothing else: orientation is how the editor draws the page and is
    // never sent.
    try std.testing.expect(std.mem.indexOf(u8, page_html, "rotation: model.rotation || 0") != null);
    // The page size and the picture of it move together: a form reading 320
    // while the printer takes 304 lays the fields out against a label that will
    // never exist, and they come out clipped.
    try std.testing.expect(std.mem.indexOf(u8, page_html, "function usePage(") != null);
    // The page sizes its field boxes from the renderer's own metrics, marks
    // the fields the renderer will clip, and can save and load a layout.
    try std.testing.expect(std.mem.indexOf(u8, page_html, "/api/label/metrics") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "/api/label/sizes") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "id=\"label-size\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "/api/label/track") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "clipped") != null);
    // The editor draws literal text only. Source controls were taken out on
    // purpose; a source UI is a later design of its own, not this one back.
    try std.testing.expect(std.mem.indexOf(u8, page_html, "/api/sources") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "id=\"source\"") == null);
    // The printer comes from a scan, and the page names the list after what
    // the scan found rather than asking for a tty or a MAC by hand.
    try std.testing.expect(std.mem.indexOf(u8, page_html, "/api/devices/scan") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_html, "Found Niimbot devices") != null);
    inline for (control) |name| {
        const needle = "id=\"" ++ name ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, page_html, needle) != null);
    }
}

fn postToken(http: *HttpService, allocator: std.mem.Allocator, path: []const u8, body: []const u8) !Response {
    const query = try std.fmt.allocPrint(allocator, "token={s}", .{&http.token_hex});
    defer allocator.free(query);
    return http.dispatch(.{ .io = undefined, .method = .POST, .path = path, .query = query, .body = body });
}

fn send(http: *HttpService, allocator: std.mem.Allocator, method: std.http.Method, path: []const u8, body: []const u8) !Response {
    const query = try std.fmt.allocPrint(allocator, "token={s}", .{&http.token_hex});
    defer allocator.free(query);
    return http.dispatch(.{ .io = undefined, .method = method, .path = path, .query = query, .body = body });
}

fn expectBodyContains(body: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, body, needle) != null);
}

test "a runtime source can be replaced and deleted, a plugin source cannot" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    const fiber = try mountHttpWithExample(&ctx);
    const http = ctx.require(HttpService, "http");
    const sources = ctx.require(Sources, "sources");

    // The example record belongs to a plugin: the delete route must refuse it
    // and leave it registered.
    const refused = try send(http, gpa, .DELETE, "/api/sources/example", "");
    defer if (refused.owned) gpa.free(refused.body);
    try std.testing.expectEqual(std.http.Status.bad_request, refused.status);
    try expectBodyContains(refused.body, "plugin");
    try std.testing.expect(sources.find("example") != null);

    const missing = try send(http, gpa, .DELETE, "/api/sources/nothere", "");
    defer if (missing.owned) gpa.free(missing.body);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);

    const first = try postToken(http, gpa, "/api/sources", "{\"name\":\"article\",\"json\":\"{\\\"sku\\\":\\\"NB-1\\\"}\"}");
    defer if (first.owned) gpa.free(first.body);
    try std.testing.expectEqual(std.http.Status.ok, first.status);
    try expectBodyContains(first.body, "\"ok\":true");
    try std.testing.expect(!std.mem.startsWith(u8, first.body, "{\"ok\":true,\"replaced\""));

    const again = try postToken(http, gpa, "/api/sources", "{\"name\":\"article\",\"json\":\"{\\\"sku\\\":\\\"NB-2\\\"}\"}");
    defer if (again.owned) gpa.free(again.body);
    try expectBodyContains(again.body, "replaced");
    try std.testing.expectEqualStrings("{\"sku\":\"NB-2\"}", sources.find("article").?);

    const runtime = try send(http, gpa, .GET, "/api/runtime-sources", "");
    defer if (runtime.owned) gpa.free(runtime.body);
    try std.testing.expectEqual(std.http.Status.ok, runtime.status);
    try expectBodyContains(runtime.body, "article");
    try std.testing.expect(!std.mem.eql(u8, runtime.body, "{\"sources\":[\"example\"]}"));

    const removed = try send(http, gpa, .DELETE, "/api/sources/article", "");
    defer if (removed.owned) gpa.free(removed.body);
    try std.testing.expectEqual(std.http.Status.ok, removed.status);
    try std.testing.expect(sources.find("article") == null);

    const gone = try send(http, gpa, .GET, "/api/runtime-sources", "");
    defer if (gone.owned) gpa.free(gone.body);
    try std.testing.expectEqualStrings("{\"sources\":[]}", gone.body);

    // A delete twice is a 404, not a double free.
    const twice = try send(http, gpa, .DELETE, "/api/sources/article", "");
    defer if (twice.owned) gpa.free(twice.body);
    try std.testing.expectEqual(std.http.Status.not_found, twice.status);

    // Disposing the http fiber still drops whatever is left over.
    const left = try postToken(http, gpa, "/api/sources", "{\"name\":\"left\",\"json\":\"{\\\"a\\\":1}\"}");
    defer if (left.owned) gpa.free(left.body);
    fiber.dispose();
    try std.testing.expect(sources.find("left") == null);
    try std.testing.expect(sources.find("example") != null);
}

test "render routes reject a method the prefix does not serve" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const response = try send(http, gpa, .PUT, "/api/sources/example", "");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.not_found, response.status);
}

test "a field's own newline is escaped in the track answer" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try mountHttpWithExample(&ctx);
    const http = ctx.require(HttpService, "http");

    const response = try postToken(http, gpa, "/api/label/track", "{\"source\":\"\",\"fields\":[{\"text\":\"ONE\\nTWO\",\"x\":4,\"size\":16,\"align_mode\":\"left\"}]}");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);

    // The answer must parse: a raw newline inside a JSON string would not.
    const Parsed = struct { origin: []const u8, text: []const u8 = "", x: usize };
    const Envelope = struct { fields: []const Parsed };
    const parsed = try std.json.parseFromSlice(Envelope, gpa, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("literal", parsed.value.fields[0].origin);
    try std.testing.expectEqualStrings("ONE\nTWO", parsed.value.fields[0].text);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.fields[0].x);
}

test "the track route reports where each field's text comes from" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try mountHttpWithExample(&ctx);
    const http = ctx.require(HttpService, "http");

    // The record is named once for the whole body, the way the editor sends
    // it, and each field says which of its keys it reads.
    const response = try postToken(http, gpa, "/api/label/track", "{\"source\":\"example\",\"fields\":[{\"key\":\"sku\"},{\"text\":\"hand written\"},{\"key\":\"nothing\"}]}");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);

    const Parsed = struct {
        origin: []const u8,
        text: []const u8 = "",
        x: usize = 0,
    };
    const Envelope = struct { fields: []const Parsed };
    const parsed = try std.json.parseFromSlice(Envelope, gpa, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.fields.len);
    try std.testing.expectEqualStrings("record", parsed.value.fields[0].origin);
    try std.testing.expectEqualStrings("NB-1", parsed.value.fields[0].text);
    try std.testing.expectEqualStrings("literal", parsed.value.fields[1].origin);
    // A key the record does not carry is its own answer, not a missing record.
    try std.testing.expectEqualStrings("missing-key", parsed.value.fields[2].origin);

    const no_record = try postToken(http, gpa, "/api/label/track", "{\"source\":\"nothere\",\"fields\":[{\"key\":\"sku\"}]}");
    defer if (no_record.owned) gpa.free(no_record.body);
    const missing = try std.json.parseFromSlice(Envelope, gpa, no_record.body, .{});
    defer missing.deinit();
    try std.testing.expectEqualStrings("unknown-source", missing.value.fields[0].origin);

    // The two origins that mean "installed, but nothing to show".
    const install = try postToken(http, gpa, "/api/sources", "{\"name\":\"shapes\",\"json\":\"{\\\"nested\\\":{\\\"a\\\":1},\\\"list\\\":[1,2],\\\"n\\\":7,\\\"b\\\":true}\"}");
    defer if (install.owned) gpa.free(install.body);
    try std.testing.expectEqual(std.http.Status.ok, install.status);
    const shapes = try postToken(http, gpa, "/api/label/track", "{\"source\":\"shapes\",\"fields\":[{\"key\":\"nested\"},{\"key\":\"list\"},{\"key\":\"n\"},{\"key\":\"b\"}]}");
    defer if (shapes.owned) gpa.free(shapes.body);
    const shape_fields = try std.json.parseFromSlice(Envelope, gpa, shapes.body, .{});
    defer shape_fields.deinit();
    try std.testing.expectEqual(@as(usize, 4), shape_fields.value.fields.len);
    try std.testing.expectEqualStrings("structured", shape_fields.value.fields[0].origin);
    try std.testing.expectEqualStrings("structured", shape_fields.value.fields[1].origin);
    try std.testing.expectEqualStrings("record", shape_fields.value.fields[2].origin);
    try std.testing.expectEqualStrings("7", shape_fields.value.fields[2].text);
    try std.testing.expectEqualStrings("record", shape_fields.value.fields[3].origin);
    try std.testing.expectEqualStrings("true", shape_fields.value.fields[3].text);

    // A key is not a record name: the same name under a different key is what
    // makes this route useful.
    const other = try postToken(http, gpa, "/api/label/track", "{\"source\":\"example\",\"fields\":[{\"key\":\"title\"}]}");
    defer if (other.owned) gpa.free(other.body);
    const title = try std.json.parseFromSlice(Envelope, gpa, other.body, .{});
    defer title.deinit();
    try std.testing.expectEqualStrings("record", title.value.fields[0].origin);
    try std.testing.expectEqualStrings("Niimbench", title.value.fields[0].text);
}

test "a record that is not plain text is not written into the track answer" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const install = try postToken(http, gpa, "/api/sources", "{\"name\":\"quoted\",\"json\":\"{\\\"sku\\\":\\\"a\\\\\\\"b\\\"}\"}");
    defer if (install.owned) gpa.free(install.body);
    try std.testing.expectEqual(std.http.Status.ok, install.status);

    const response = try postToken(http, gpa, "/api/label/track", "{\"source\":\"quoted\",\"fields\":[{\"key\":\"sku\"}]}");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const Envelope = struct { fields: []const struct { origin: []const u8, x: usize = 0 } };
    const parsed = try std.json.parseFromSlice(Envelope, gpa, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("dynamic", parsed.value.fields[0].origin);
}

test "alignment reaches the render route and the track answer" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    _ = try mountHttpWithExample(&ctx);
    const http = ctx.require(HttpService, "http");

    const Parsed = struct { width: usize, height: usize, pixels_b64: []const u8 };
    const body = "{{\"width\":200,\"height\":16,\"source\":\"example\",\"fields\":[{{\"key\":\"sku\",\"x\":150,\"y\":0,\"size\":16,\"align_mode\":\"{s}\"}}]}}";
    var frames: [3][]u8 = undefined;
    var count: usize = 0;
    defer for (frames[0..count]) |frame| gpa.free(frame);
    for ([_][]const u8{ "left", "center", "right" }) |mode| {
        const request = try std.fmt.allocPrint(gpa, body, .{mode});
        defer gpa.free(request);
        const response = try postToken(http, gpa, "/api/render", request);
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        const parsed = try std.json.parseFromSlice(Parsed, gpa, response.body, .{});
        defer parsed.deinit();
        const len = try std.base64.standard.Decoder.calcSizeForSlice(parsed.value.pixels_b64);
        const frame = try gpa.alloc(u8, len);
        std.base64.standard.Decoder.decode(frame, parsed.value.pixels_b64) catch {
            gpa.free(frame);
            return error.TestUnexpectedResult;
        };
        frames[count] = frame;
        count += 1;
    }
    // Left, centre, and right place the same value at three different edges.
    for (1..count) |i| {
        try std.testing.expect(!std.mem.eql(u8, frames[0], frames[i]));
    }

    // The track answer carries the placed edge, so the editor draws its box
    // where the ink is.
    const Entry = struct { origin: []const u8, text: []const u8 = "", x: usize };
    const Envelope = struct { fields: []const Entry };
    for ([_]struct { mode: []const u8, x: usize }{
        .{ .mode = "left", .x = 150 },
        .{ .mode = "center", .x = try label.alignedX(gpa, .{ .text = "NB-1", .x = 150, .size = 16, .align_mode = .center }, "") },
        .{ .mode = "right", .x = try label.alignedX(gpa, .{ .text = "NB-1", .x = 150, .size = 16, .align_mode = .right }, "") },
    }) |want| {
        const request = try std.fmt.allocPrint(gpa, "{{\"source\":\"example\",\"fields\":[{{\"key\":\"sku\",\"x\":150,\"size\":16,\"align_mode\":\"{s}\"}}]}}", .{want.mode});
        defer gpa.free(request);
        const response = try postToken(http, gpa, "/api/label/track", request);
        defer if (response.owned) gpa.free(response.body);
        const parsed = try std.json.parseFromSlice(Envelope, gpa, response.body, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("record", parsed.value.fields[0].origin);
        try std.testing.expectEqualStrings("NB-1", parsed.value.fields[0].text);
        try std.testing.expectEqual(want.x, parsed.value.fields[0].x);
    }

    // An angle the enum does not name is rejected rather than drawn as left.
    const bad = try postToken(http, gpa, "/api/render", "{\"width\":100,\"height\":16,\"fields\":[{\"text\":\"AB\",\"align_mode\":\"middle\"}]}");
    defer if (bad.owned) gpa.free(bad.body);
    try std.testing.expectEqual(std.http.Status.bad_request, bad.status);
}

const InkBox = struct { width: usize, height: usize };

/// The size of the box that carries ink, which is how a turn of the letters
/// shows up without the page changing size.
fn inkBox(pixels: []const u8, width: usize, height: usize) InkBox {
    var min_x: usize = width;
    var min_y: usize = height;
    var max_x: usize = 0;
    var max_y: usize = 0;
    for (0..height) |y| {
        for (0..width) |x| {
            if (pixels[y * width + x] != 0) continue;
            if (x < min_x) min_x = x;
            if (y < min_y) min_y = y;
            if (x > max_x) max_x = x;
            if (y > max_y) max_y = y;
        }
    }
    if (min_x > max_x) return .{ .width = 0, .height = 0 };
    return .{ .width = max_x - min_x + 1, .height = max_y - min_y + 1 };
}

test "a field's direction is accepted and ignored" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");

    const render = struct {
        fn run(allocator: std.mem.Allocator, service: *HttpService, rotation: i32, direction: u16) ![]u8 {
            const request = try std.fmt.allocPrint(allocator, "{{\"width\":48,\"height\":96,\"fields\":[{{\"text\":\"AB\",\"x\":4,\"y\":4,\"size\":16,\"direction\":{d},\"rotation\":{d}}}]}}", .{ direction, rotation });
            defer allocator.free(request);
            const response = try postToken(service, allocator, "/api/render", request);
            defer if (response.owned) allocator.free(response.body);
            if (response.status != .ok) return error.RenderFailed;
            return allocator.dupe(u8, response.body);
        }
    }.run;

    // `direction` changes nothing. `rotation` is the field's own angle.
    const first = try render(gpa, http, 0, 0);
    defer gpa.free(first);
    const second = try render(gpa, http, 0, 270);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
    const turned = try render(gpa, http, 90, 0);
    defer gpa.free(turned);
    try std.testing.expect(!std.mem.eql(u8, first, turned));
}

test "render turns the letters, not the roll" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");

    const Parsed = struct { width: usize, height: usize, pixels_b64: []const u8 };
    var decoded: [4][]u8 = undefined;
    var decoded_count: usize = 0;
    defer for (decoded[0..decoded_count]) |frame| gpa.free(frame);

    for ([_]i32{ 0, 90 }, 0..) |degrees, slot| {
        const request = try std.fmt.allocPrint(gpa, "{{\"width\":48,\"height\":96,\"fields\":[{{\"text\":\"AB\",\"x\":2,\"y\":2,\"size\":16,\"rotation\":{d}}}]}}", .{degrees});
        defer gpa.free(request);
        const response = try postToken(http, gpa, "/api/render", request);
        defer if (response.owned) gpa.free(response.body);
        try std.testing.expectEqual(std.http.Status.ok, response.status);
        const parsed = try std.json.parseFromSlice(Parsed, gpa, response.body, .{});
        defer parsed.deinit();
        // The printer image is always the roll. Vertical only turns the letters
        // so they run along the tape; the editor turns the preview itself.
        try std.testing.expectEqual(@as(usize, 48), parsed.value.width);
        try std.testing.expectEqual(@as(usize, 96), parsed.value.height);
        const len = try std.base64.standard.Decoder.calcSizeForSlice(parsed.value.pixels_b64);
        const frame = try gpa.alloc(u8, len);
        std.base64.standard.Decoder.decode(frame, parsed.value.pixels_b64) catch {
            gpa.free(frame);
            return error.TestUnexpectedResult;
        };
        decoded[slot] = frame;
        decoded_count += 1;
    }

    // No two quarter turns draw the same page, so the angle reaches the pixels.
    for (1..decoded_count) |i| {
        try std.testing.expect(!std.mem.eql(u8, decoded[0], decoded[i]));
    }
    // Horizontal ink is a wide line. Vertical ink runs down the tape, so the
    // same letters are taller than they are wide, on a page of the same size.
    const upright = inkBox(decoded[0], 48, 96);
    const turned = inkBox(decoded[1], 48, 96);
    try std.testing.expect(upright.width > upright.height);
    try std.testing.expect(turned.height > turned.width);
}

test "raw pixels still render and print through the http plugin" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");

    var raw: [32]u8 = undefined;
    @memset(&raw, 255);
    raw[5] = 0;
    var encoded: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&encoded, &raw);
    // Built by hand: a format string would have to escape both the JSON braces
    // and the base64 call's own `{s}`.
    const body = try std.mem.concat(gpa, u8, &.{ "{\"width\":8,\"height\":4,\"pixels_b64\":\"", b64, "\"}" });
    defer gpa.free(body);

    const response = try postToken(http, gpa, "/api/render", body);
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const Parsed = struct { width: usize, height: usize, pixels_b64: []const u8 };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, response.body, .{});
    defer parsed.deinit();
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(parsed.value.pixels_b64);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, parsed.value.pixels_b64);
    try std.testing.expectEqualSlices(u8, &raw, decoded);
}

test "a source posted at runtime is rendered, listed, and dropped with the http fiber" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    const fiber = try mountHttpFiber(&ctx);
    const http = ctx.require(HttpService, "http");
    const sources = ctx.require(Sources, "sources");

    const installed = try postToken(http, gpa, "/api/sources", "{\"name\":\"runtime\",\"json\":\"{\\\"sku\\\":\\\"NB-9\\\"}\"}");
    defer if (installed.owned) gpa.free(installed.body);
    try std.testing.expectEqual(std.http.Status.ok, installed.status);
    try std.testing.expect(sources.find("runtime") != null);

    const rendered = try postToken(http, gpa, "/api/render", "{\"width\":48,\"height\":16,\"source\":\"runtime\",\"fields\":[{\"key\":\"sku\",\"x\":1,\"y\":1}]}");
    defer if (rendered.owned) gpa.free(rendered.body);
    try std.testing.expectEqual(std.http.Status.ok, rendered.status);

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const listed = try http.dispatch(.{ .io = undefined, .method = .GET, .path = "/api/sources", .query = query, .body = "" });
    defer if (listed.owned) gpa.free(listed.body);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, "runtime") != null);

    fiber.dispose();
    try std.testing.expect(sources.find("runtime") == null);
}

test "a posted source that is not a json object is rejected" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const response = try postToken(http, gpa, "/api/sources", "{\"name\":\"bad\",\"json\":\"[1,2]\"}");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);
    try std.testing.expect(http.sources.find("bad") == null);
}

test "a background with no text fields is the rendered label" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");

    var raw: [12]u8 = undefined;
    @memset(&raw, 180);
    raw[0] = 0;
    var encoded: [32]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&encoded, &raw);
    const body = try std.mem.concat(gpa, u8, &.{
        "{\"width\":4,\"height\":3,\"fields\":[],\"background_b64\":\"",
        b64,
        "\"}",
    });
    defer gpa.free(body);

    const response = try postToken(http, gpa, "/api/render", body);
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const Parsed = struct { width: usize, height: usize, pixels_b64: []const u8 };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, response.body, .{});
    defer parsed.deinit();
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(parsed.value.pixels_b64);
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, parsed.value.pixels_b64);
    try std.testing.expectEqualSlices(u8, &raw, decoded);
}

test "a failed render still reports the label size" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const response = try postToken(http, gpa, "/api/render", "{\"width\":120,\"height\":40,\"fields\":[]}");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "NothingToPrint") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"width\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"height\":40") != null);

    const missing = try postToken(http, gpa, "/api/render", "{\"width\":80,\"height\":24,\"source\":\"nope\",\"fields\":[{\"text\":\"x\"}]}");
    defer if (missing.owned) gpa.free(missing.body);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "UnknownSource") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing.body, "\"width\":80") != null);
}

test "the label metrics route reports every font's advance table" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try http.dispatch(.{ .io = undefined, .method = .GET, .path = "/api/label/metrics", .query = query, .body = "" });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const Table = struct {
        id: []const u8,
        name: []const u8,
        line_units: u64,
        missing: u64,
        advances: []const []const u64,
    };
    const Parsed = struct {
        default: []const u8,
        max_size: usize,
        fonts: []const Table,
    };
    const parsed = try std.json.parseFromSlice(Parsed, gpa, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, label.max_size), parsed.value.max_size);
    try std.testing.expectEqualStrings(font.default_id, parsed.value.default);
    try std.testing.expectEqual(font.fonts.len, parsed.value.fonts.len);
    // The editor's arithmetic on each table gives the width the renderer draws.
    const text = "Niimbench \u{e9}\u{2603}";
    for (parsed.value.fonts, &font.fonts) |table, *entry| {
        try std.testing.expectEqualStrings(entry.id, table.id);
        try std.testing.expectEqualStrings(entry.name, table.name);
        var advances: std.AutoHashMapUnmanaged(u64, u64) = .empty;
        defer advances.deinit(gpa);
        for (table.advances) |run| {
            for (run[1..], 0..) |units, i| try advances.put(gpa, run[0] + i, units);
        }
        var units: u64 = 0;
        var it = (try std.unicode.Utf8View.init(text)).iterator();
        while (it.nextCodepoint()) |cp| units += advances.get(cp) orelse table.missing;
        for ([_]usize{ 7, 16, 23, 64 }) |size| {
            const editor_width = (units * size + table.line_units - 1) / table.line_units;
            try std.testing.expectEqual(label.lineWidth(&entry.face, text, size), editor_width);
        }
    }
}

test "render and track refuse a font the build does not carry" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const rendered = try postToken(http, gpa, "/api/render", "{\"width\":100,\"height\":20,\"fields\":[{\"text\":\"AB\",\"font\":\"comic-sans\"}]}");
    defer if (rendered.owned) gpa.free(rendered.body);
    try std.testing.expectEqual(std.http.Status.bad_request, rendered.status);
    try std.testing.expect(std.mem.indexOf(u8, rendered.body, "UnknownFont") != null);
    const tracked = try postToken(http, gpa, "/api/label/track", "{\"source\":\"\",\"fields\":[{\"text\":\"AB\",\"font\":\"comic-sans\"}]}");
    defer if (tracked.owned) gpa.free(tracked.body);
    try std.testing.expectEqual(std.http.Status.bad_request, tracked.status);
    try std.testing.expect(std.mem.indexOf(u8, tracked.body, "UnknownFont") != null);
    // A font the build carries renders.
    const known = try postToken(http, gpa, "/api/render", "{\"width\":100,\"height\":20,\"fields\":[{\"text\":\"AB\",\"font\":\"hack\"}]}");
    defer if (known.owned) gpa.free(known.body);
    try std.testing.expectEqual(std.http.Status.ok, known.status);
}

test "label sizes for a model omit the other series" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try http.dispatch(.{ .io = undefined, .method = .GET, .path = "/api/label/sizes", .query = query, .body = "" });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"dots_per_mm\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"b21\":{\"max_width\":384,\"default\":\"50x30\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"id\":\"50x30\",\"width_mm\":50,\"height_mm\":30,\"round\":false,\"width\":384,\"height\":240") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"d11\":{\"max_width\":96,\"default\":\"12x40\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"id\":\"15x30\",\"width_mm\":15,\"height_mm\":30,\"round\":false,\"width\":96,\"height\":240") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"b18\":{\"max_width\":384,\"default\":\"b18-14x50\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"id\":\"b18-14x50\",\"width_mm\":14,\"height_mm\":50,\"round\":false,\"width\":112,\"height\":400") != null);

    const d11_at = std.mem.indexOf(u8, response.body, "\"d11\":").?;
    const d110_at = std.mem.indexOf(u8, response.body, "\"d110\":").?;
    const d11_body = response.body[d11_at..d110_at];
    try std.testing.expect(std.mem.indexOf(u8, d11_body, "50x30") == null);
    const b18_at = std.mem.indexOf(u8, response.body, "\"b18\":").?;
    const b21_at = std.mem.indexOf(u8, response.body, "\"b21\":").?;
    const b18_body = response.body[b18_at..b21_at];
    try std.testing.expect(std.mem.indexOf(u8, b18_body, "50x30") == null);
    try std.testing.expect(std.mem.indexOf(u8, b18_body, "12x40") == null);
}

test "the startup url sets a cookie and the address drops the token" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);

    const exchanged = try http.dispatch(.{
        .io = undefined,
        .method = .GET,
        .path = "/",
        .query = query,
        .body = "",
    });
    try std.testing.expectEqual(std.http.Status.found, exchanged.status);
    try std.testing.expect(exchanged.set_cookie);
    try std.testing.expectEqualStrings("/", exchanged.location.?);

    const cookie = try std.fmt.allocPrint(gpa, "niimbench={s}", .{&http.token_hex});
    defer gpa.free(cookie);
    const authed = try http.dispatch(.{
        .io = undefined,
        .method = .GET,
        .path = "/api/health",
        .query = "",
        .body = "",
        .cookie = cookie,
    });
    defer if (authed.owned) gpa.free(authed.body);
    try std.testing.expectEqual(std.http.Status.ok, authed.status);

    const rejected = try http.dispatch(.{
        .io = undefined,
        .method = .GET,
        .path = "/api/health",
        .query = "",
        .body = "",
        .cookie = "niimbench=nope",
    });
    try std.testing.expectEqual(std.http.Status.unauthorized, rejected.status);
}

test "dispatch rejects a missing token" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const response = try http.dispatch(.{
        .io = undefined,
        .method = .GET,
        .path = "/api/health",
        .query = "",
        .body = "",
    });
    try std.testing.expectEqual(std.http.Status.unauthorized, response.status);
}

fn fakeUsbFinder(_: std.Io, _: std.mem.Allocator, _: bool, out: *discovery.Found) !void {
    try out.add(.usb, "/dev/ttyACM9", "NIIMBOT B21", .b21, 768, false);
}

/// The passive answer knows no printer; the inquiry is what finds this one, so
/// a test can see which scan the page asked for.
fn fakeBluetoothFinder(_: std.Io, _: std.mem.Allocator, discover: bool, out: *discovery.Found) !void {
    if (!discover) return;
    try out.add(.bluetooth, "AA:BB:CC:DD:EE:FF", "NIIMBOT D110", .d110, 2304, true);
}

fn failingFinder(_: std.Io, _: std.mem.Allocator, _: bool, _: *discovery.Found) !void {
    return error.NoBluetooth;
}

const FoundDevice = struct {
    conn: []const u8,
    addr: []const u8,
    name: []const u8,
    model: ?[]const u8 = null,
    model_id: u16,
    spp: bool,
};

const DeviceList = struct {
    scanned: bool,
    devices: []const FoundDevice,
};

fn listDevicesResponse(http: *HttpService, query: []const u8) !Response {
    return http.dispatch(.{ .io = std.testing.io, .method = .GET, .path = "/api/devices", .query = query, .body = "" });
}

fn scanDevicesResponse(http: *HttpService, query: []const u8, body: []const u8) !Response {
    return http.dispatch(.{ .io = std.testing.io, .method = .POST, .path = "/api/devices/scan", .query = query, .body = body });
}

test "the device routes report what the transports found" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const devices = ctx.require(discovery.Registry, "devices");
    devices.usb = fakeUsbFinder;
    devices.bluetooth = fakeBluetoothFinder;

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);

    // No scan has run, and the answer says so instead of pretending.
    const cold = try listDevicesResponse(http, query);
    defer if (cold.owned) gpa.free(cold.body);
    try std.testing.expectEqual(std.http.Status.ok, cold.status);
    const cold_list = try std.json.parseFromSlice(DeviceList, gpa, cold.body, .{});
    defer cold_list.deinit();
    try std.testing.expect(!cold_list.value.scanned);
    try std.testing.expectEqual(@as(usize, 0), cold_list.value.devices.len);

    // The passive scan probes the serial ports and does not start an inquiry.
    const passive = try scanDevicesResponse(http, query, "{}");
    defer if (passive.owned) gpa.free(passive.body);
    try std.testing.expectEqual(std.http.Status.ok, passive.status);
    const passive_list = try std.json.parseFromSlice(DeviceList, gpa, passive.body, .{});
    defer passive_list.deinit();
    try std.testing.expect(passive_list.value.scanned);
    try std.testing.expectEqual(@as(usize, 1), passive_list.value.devices.len);
    try std.testing.expectEqualStrings("usb", passive_list.value.devices[0].conn);
    try std.testing.expectEqualStrings("/dev/ttyACM9", passive_list.value.devices[0].addr);
    try std.testing.expectEqualStrings("b21", passive_list.value.devices[0].model.?);
    try std.testing.expectEqual(@as(u16, 768), passive_list.value.devices[0].model_id);

    // `discover` is what asks Bluetooth for an inquiry.
    const active = try scanDevicesResponse(http, query, "{\"discover\":true}");
    defer if (active.owned) gpa.free(active.body);
    const active_list = try std.json.parseFromSlice(DeviceList, gpa, active.body, .{});
    defer active_list.deinit();
    try std.testing.expectEqual(@as(usize, 2), active_list.value.devices.len);
    try std.testing.expectEqualStrings("bluetooth", active_list.value.devices[1].conn);
    try std.testing.expectEqualStrings("AA:BB:CC:DD:EE:FF", active_list.value.devices[1].addr);
    try std.testing.expectEqualStrings("d110", active_list.value.devices[1].model.?);
    try std.testing.expect(active_list.value.devices[1].spp);

    // The cached answer is what `GET` serves without scanning again.
    const warm = try listDevicesResponse(http, query);
    defer if (warm.owned) gpa.free(warm.body);
    try std.testing.expectEqualStrings(active.body, warm.body);
}

test "a finder that fails does not hide the other transport" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const devices = ctx.require(discovery.Registry, "devices");
    devices.usb = failingFinder;
    devices.bluetooth = fakeBluetoothFinder;

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try scanDevicesResponse(http, query, "{\"discover\":true}");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try std.json.parseFromSlice(DeviceList, gpa, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.devices.len);
    try std.testing.expectEqualStrings("bluetooth", parsed.value.devices[0].conn);
}

test "a body that is not a scan request is the passive scan" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const devices = ctx.require(discovery.Registry, "devices");
    devices.usb = fakeUsbFinder;
    devices.bluetooth = fakeBluetoothFinder;

    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);
    const response = try scanDevicesResponse(http, query, "not json");
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.ok, response.status);
    const parsed = try std.json.parseFromSlice(DeviceList, gpa, response.body, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.devices.len);
    try std.testing.expectEqualStrings("usb", parsed.value.devices[0].conn);
}

test "the device registry goes away with its fiber" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    const fiber = try ctx.mount("devices", .{ .name = "devices", .apply = applyDevices });
    try std.testing.expect(ctx.get("devices") != null);
    fiber.dispose();
    try std.testing.expect(ctx.get("devices") == null);
}

test "the catalogue answers by default and the cloud needs opting in" {
    const gpa = std.testing.allocator;
    var catalogue = try labels.load(gpa);
    defer catalogue.deinit();

    // A roll the catalogue carries is answered locally whether or not the
    // caller allowed the cloud, so it can never reach the network by accident.
    switch (rollSource(&catalogue, "01222281", false)) {
        .catalogue => |mm| {
            try std.testing.expectEqual(@as(u16, 12), mm.width_mm);
            try std.testing.expectEqual(@as(u16, 40), mm.height_mm);
            try std.testing.expectEqualStrings("catalogue", mm.source);
        },
        else => return error.ExpectedCatalogue,
    }
    switch (rollSource(&catalogue, "01222281", true)) {
        .catalogue => {},
        else => return error.ExpectedCatalogue,
    }

    // A barcode the catalogue does not carry is an error unless the caller
    // asked for the cloud.
    switch (rollSource(&catalogue, "00000000", false)) {
        .unknown => {},
        else => return error.ExpectedUnknown,
    }
    switch (rollSource(&catalogue, "00000000", true)) {
        .cloud => {},
        else => return error.ExpectedCloud,
    }
}

test "the trace records what the routes did, and reads back oldest first" {
    const gpa = std.testing.allocator;
    var ctx = cordis.Context.init(gpa);
    defer ctx.deinit();
    // The trace is its own plugin, so this is the one test that mounts it.
    _ = try ctx.mount("trace", .{ .name = "trace", .apply = trace_mod.applyTrace });
    try mountHttp(&ctx);
    const http = ctx.require(HttpService, "http");
    const query = try std.fmt.allocPrint(gpa, "token={s}", .{&http.token_hex});
    defer gpa.free(query);

    // A failed print is the case worth recording: the answer alone says
    // "FileNotFound", and the line says what was asked for.
    const response = try http.dispatch(.{
        .io = std.testing.io,
        .method = .POST,
        .path = "/api/print",
        .query = query,
        .body = "{\"width\":96,\"height\":304,\"fields\":[{\"text\":\"X\",\"x\":4,\"y\":4}],\"model\":\"d110\",\"conn\":\"usb\",\"addr\":\"/no/such/tty\"}",
    });
    defer if (response.owned) gpa.free(response.body);
    try std.testing.expectEqual(std.http.Status.bad_request, response.status);

    const read = try http.dispatch(.{ .io = std.testing.io, .method = .GET, .path = "/api/trace", .query = query, .body = "" });
    defer if (read.owned) gpa.free(read.body);
    try std.testing.expectEqual(std.http.Status.ok, read.status);
    try std.testing.expect(std.mem.indexOf(u8, read.body, "opened") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.body, "print") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.body, "error") != null);
    const opened = std.mem.indexOf(u8, read.body, "opened").?;
    const failed = std.mem.indexOf(u8, read.body, "failed").?;
    try std.testing.expect(opened < failed);

    // The page posts its own lines, and a clear empties what was there.
    const posted = try http.dispatch(.{
        .io = std.testing.io,
        .method = .POST,
        .path = "/api/trace",
        .query = query,
        .body = "{\"level\":\"info\",\"source\":\"page\",\"message\":\"view: vertical\"}",
    });
    defer if (posted.owned) gpa.free(posted.body);
    try std.testing.expectEqual(std.http.Status.ok, posted.status);

    // The page's line is in the log the read route answers with.
    const after_post = try http.dispatch(.{ .io = std.testing.io, .method = .GET, .path = "/api/trace", .query = query, .body = "" });
    defer if (after_post.owned) gpa.free(after_post.body);
    try std.testing.expect(std.mem.indexOf(u8, after_post.body, "view: vertical") != null);

    const clear_query = try std.fmt.allocPrint(gpa, "{s}&clear=1", .{query});
    defer gpa.free(clear_query);
    const cleared = try http.dispatch(.{
        .io = std.testing.io,
        .method = .GET,
        .path = "/api/trace",
        .query = clear_query,
        .body = "",
    });
    defer if (cleared.owned) gpa.free(cleared.body);
    // Clearing keeps only the note that it happened.
    try std.testing.expect(std.mem.indexOf(u8, cleared.body, "cleared") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared.body, "view: vertical") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleared.body, "failed") == null);
}

test "the editor records every step of its protocol" {
    // The page's rules for a complete record, in the one place that always
    // runs. The steps are registered by being traced (`traceStep`), so the
    // source cannot list a step it never runs, and the run reports the list it
    // built so `tools/trace-test.js` can require every step of that run. This
    // holds the mechanism itself in place: remove any of these and the build
    // stops, rather than the record quietly going incomplete.
    const needed = [_][]const u8{
        // The list, and the helper that adds to it by tracing.
        "const tracedSteps = [",
        "function traceStep(",
        "tracedSteps.push(",
        // The report the harness reads, so the check is about the run and not
        // about the source.
        "traceLine(\"info\", \"protocol: \"",
        // And the protocol the harness reads it with.
    };
    for (needed) |needle| {
        if (std.mem.indexOf(u8, page_html, needle) == null) {
            std.debug.print(
                "src/editor.html no longer has {s}.\n" ++
                    "That is part of how the page's trace stays complete: reading it in tools/trace-test.js \n" ++
                    "checks the run, and this holds the mechanism in place. Put it back, or change both together.\n",
                .{needle},
            );
            return error.ProtocolMechanismMissing;
        }
    }

    // The list itself is not empty, so the mechanism is not sitting unused.
    const list_start = std.mem.indexOf(u8, page_html, "const tracedSteps = [") orelse return error.ProtocolMechanismMissing;
    const list_end = std.mem.indexOfPos(u8, page_html, list_start, "];") orelse return error.ProtocolMechanismMissing;
    try std.testing.expect(std.mem.indexOf(u8, page_html[list_start..list_end], "\"") != null);
}
