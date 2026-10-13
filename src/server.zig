const std = @import("std");
const cordis = @import("cordis.zig");
const device = @import("device.zig");
const printer = @import("printer.zig");
const raster = @import("raster.zig");

pub const page_html = @embedFile("editor.html");

pub const Sources = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    bodies: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Sources, name: []const u8, json: []const u8) !void {
        try self.names.append(self.allocator, name);
        try self.bodies.append(self.allocator, json);
    }

    pub fn remove(self: *Sources, name: []const u8) void {
        var i: usize = 0;
        while (i < self.names.items.len) : (i += 1) {
            if (!std.mem.eql(u8, self.names.items[i], name)) continue;
            _ = self.names.swapRemove(i);
            _ = self.bodies.swapRemove(i);
            return;
        }
    }

    pub fn find(self: Sources, name: []const u8) ?[]const u8 {
        for (self.names.items, self.bodies.items) |item, body| {
            if (std.mem.eql(u8, item, name)) return body;
        }
        return null;
    }
};

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
        degrees: u16,
    ) !void {
        _ = self;
        const turned = try raster.rotate(allocator, pixels, width, height, degrees);
        defer allocator.free(turned.pixels);
        if (turned.width > model.maxWidth()) return error.TooWide;
        var level = density;
        if (level > model.maxDensity()) level = model.maxDensity();
        const transport = try registry.open(conn, allocator, addr);
        var client = printer.Client.init(allocator, transport);
        defer client.deinit();
        try client.printGray(io, turned.pixels, turned.width, turned.height, level);
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
};

pub const Response = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/json",
    body: []const u8,
    owned: bool = false,
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
    sources: *Sources,

    pub fn dispatch(self: *HttpService, req: RequestView) !Response {
        const presented = queryValue(req.query, "token") orelse "";
        if (!std.mem.eql(u8, presented, &self.token_hex)) {
            return .{ .status = .unauthorized, .body = "{\"error\":\"bad token\"}" };
        }
        if (std.mem.startsWith(u8, req.path, "/api/sources/")) {
            return sourceRecord(self, req.path["/api/sources/".len..]);
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

pub fn page(_: *HttpService, _: RequestView) !Response {
    return .{ .content_type = "text/html; charset=utf-8", .body = page_html };
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

const PrintBody = struct {
    width: usize,
    height: usize,
    density: u8,
    model: []const u8,
    conn: []const u8,
    addr: []const u8,
    rotate: u16,
    pixels_b64: []const u8,
};

pub fn printJob(service: *HttpService, req: RequestView) !Response {
    const parsed = std.json.parseFromSlice(PrintBody, service.allocator, req.body, .{}) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad json\"}" };
    };
    defer parsed.deinit();
    const job = parsed.value;
    const model = raster.Model.parse(job.model) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"unknown model\"}" };
    };
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(job.pixels_b64) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad pixels\"}" };
    };
    const pixels = try service.allocator.alloc(u8, decoded_len);
    defer service.allocator.free(pixels);
    std.base64.standard.Decoder.decode(pixels, job.pixels_b64) catch {
        return .{ .status = .bad_request, .body = "{\"error\":\"bad pixels\"}" };
    };
    service.printer.submit(
        req.io,
        service.transports.*,
        service.allocator,
        model,
        job.conn,
        job.addr,
        pixels,
        job.width,
        job.height,
        job.density,
        job.rotate,
    ) catch |err| {
        const body = try std.fmt.allocPrint(service.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
        return .{ .status = .bad_request, .body = body, .owned = true };
    };
    service.ctx.emit("print/done");
    return .{ .body = "{\"ok\":true}" };
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

    var body: []u8 = &.{};
    defer if (body.len != 0) service.allocator.free(body);
    if (request.head.method.requestHasBody()) {
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
    }) catch |err| Response{
        .status = .internal_server_error,
        .body = @errorName(err),
    };
    defer if (response.owned) service.allocator.free(response.body);

    request.respond(response.body, .{
        .status = response.status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = response.content_type },
            .{ .name = "cache-control", .value = "no-store" },
        },
    }) catch {};
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
    sources: *Sources,
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
        .sources = sources,
    };
    try fillToken(service);
    return service;
}

fn destroyHttp(ptr: *anyopaque) void {
    const service: *HttpService = @ptrCast(@alignCast(ptr));
    service.routes.deinit(service.allocator);
    service.allocator.destroy(service);
}

pub fn applyHttp(ctx: *cordis.Context) !void {
    const printer_service = ctx.require(PrinterService, "printer");
    const transports = ctx.require(device.Registry, "transports");
    const sources = ctx.require(Sources, "sources");
    const service = try create(ctx, printer_service, transports, sources);
    try ctx.set("http", service, destroyHttp);
    try addRoute(service, .GET, "/api/health", health);
    try addRoute(service, .GET, "/api/ports", listPorts);
    try addRoute(service, .GET, "/api/sources", listSources);
    try addRoute(service, .POST, "/api/print", printJob);
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

pub fn applySources(ctx: *cordis.Context) !void {
    const sources = try ctx.allocator.create(Sources);
    sources.* = .{ .allocator = ctx.allocator };
    try ctx.set("sources", sources, destroySources);
}

fn destroySources(ptr: *anyopaque) void {
    const sources: *Sources = @ptrCast(@alignCast(ptr));
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
    _ = try ctx.mount("printer", .{ .name = "printer", .apply = applyPrinter });
    _ = try ctx.mount("transports", .{ .name = "transports", .apply = applyTransports });
    _ = try ctx.mount("sources", .{ .name = "sources", .apply = applySources });
    _ = try ctx.mount("http", .{
        .name = "http",
        .inject = &.{ "printer", "transports", "sources" },
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
