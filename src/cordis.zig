const std = @import("std");

/// A small Zig reading of the Cordis context paradigm (arXiv:2608.25512).
/// Plugins publish services on a context, declare `inject` coeffects, and
/// register work through reversible effects. Unload runs those effects LIFO.
pub const ApplyFn = *const fn (ctx: *Context) anyerror!void;

pub const Plugin = struct {
    name: []const u8,
    inject: []const []const u8 = &.{},
    apply: ApplyFn,
};

const Effect = struct {
    run: *const fn (state: *anyopaque) void,
    state: *anyopaque,
};

pub const Listener = struct {
    name: []const u8,
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque) void,
};

pub const Fiber = struct {
    id: []const u8,
    plugin_name: []const u8,
    inject: []const []const u8,
    apply_fn: ApplyFn,
    active: bool = false,
    disposed: bool = false,
    dropping: bool = false,
    effects: std.ArrayList(Effect) = .empty,
    owner: *Context,

    pub fn dispose(self: *Fiber) void {
        if (self.disposed) return;
        self.disposed = true;
        self.drop();
    }

    /// Run inverses LIFO and mark the fiber inactive. A later reconcile may
    /// apply it again when its coeffects return. `dispose` is permanent.
    pub fn drop(self: *Fiber) void {
        if (self.dropping) return;
        if (!self.active and self.effects.items.len == 0) return;
        self.dropping = true;
        self.active = false;
        while (self.effects.pop()) |effect| {
            effect.run(effect.state);
        }
        self.dropping = false;
    }
};

const Slot = struct {
    ptr: *anyopaque,
    fiber: *Fiber,
};

const SetState = struct {
    ctx: *Context,
    key: []u8,
    ptr: *anyopaque,
    destroy: ?*const fn (ptr: *anyopaque) void,
};

const ListenState = struct {
    ctx: *Context,
    name: []u8,
    call_ctx: *anyopaque,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap(Slot),
    fibers: std.ArrayList(*Fiber) = .empty,
    listeners: std.ArrayList(Listener) = .empty,
    reconciling: bool = false,
    applying: ?*Fiber = null,
    http_host: []const u8 = "127.0.0.1",
    http_port: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .services = std.StringHashMap(Slot).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        var i: usize = self.fibers.items.len;
        while (i > 0) {
            i -= 1;
            self.fibers.items[i].dispose();
        }
        for (self.fibers.items) |fiber| {
            for (fiber.inject) |key| self.allocator.free(key);
            self.allocator.free(fiber.inject);
            self.allocator.free(fiber.id);
            fiber.effects.deinit(self.allocator);
            self.allocator.destroy(fiber);
        }
        self.fibers.deinit(self.allocator);
        self.listeners.deinit(self.allocator);
        self.services.deinit();
    }

    pub fn mount(self: *Context, id: []const u8, plugin: Plugin) !*Fiber {
        for (self.fibers.items) |existing| {
            if (std.mem.eql(u8, existing.id, id)) return error.DuplicateId;
        }
        const fiber = try self.allocator.create(Fiber);
        errdefer self.allocator.destroy(fiber);
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        const inject_copy = try self.dupeKeys(plugin.inject);
        errdefer {
            for (inject_copy) |key| self.allocator.free(key);
            self.allocator.free(inject_copy);
        }
        fiber.* = .{
            .id = id_copy,
            .plugin_name = plugin.name,
            .inject = inject_copy,
            .apply_fn = plugin.apply,
            .owner = self,
        };
        try self.fibers.append(self.allocator, fiber);
        self.reconcile() catch |err| {
            fiber.dispose();
            _ = self.fibers.pop();
            for (fiber.inject) |key| self.allocator.free(key);
            self.allocator.free(fiber.inject);
            self.allocator.free(fiber.id);
            fiber.effects.deinit(self.allocator);
            self.allocator.destroy(fiber);
            return err;
        };
        return fiber;
    }

    pub fn reconcile(self: *Context) !void {
        if (self.reconciling) return;
        self.reconciling = true;
        defer self.reconciling = false;
        var progressed = true;
        while (progressed) {
            progressed = false;
            for (self.fibers.items) |fiber| {
                if (fiber.disposed or fiber.active) continue;
                if (!self.ready(fiber)) continue;
                try self.activate(fiber);
                progressed = true;
            }
        }
    }

    pub fn effect(self: *Context, run: *const fn (state: *anyopaque) void, state: *anyopaque) !void {
        const fiber = self.applying orelse return error.NoActiveFiber;
        try fiber.effects.append(self.allocator, .{ .run = run, .state = state });
    }

    pub fn set(
        self: *Context,
        key: []const u8,
        ptr: *anyopaque,
        destroy: ?*const fn (ptr: *anyopaque) void,
    ) !void {
        const fiber = self.applying orelse return error.NoActiveFiber;
        if (self.services.contains(key)) return error.ServiceExists;
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const state = try self.allocator.create(SetState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .ctx = self, .key = key_copy, .ptr = ptr, .destroy = destroy };
        try self.effect(removeService, state);
        try self.services.put(key_copy, .{ .ptr = ptr, .fiber = fiber });
        if (!self.reconciling) try self.reconcile();
    }

    pub fn get(self: *Context, key: []const u8) ?*anyopaque {
        const slot = self.services.get(key) orelse return null;
        return slot.ptr;
    }

    pub fn require(self: *Context, comptime T: type, key: []const u8) *T {
        const ptr = self.get(key) orelse @panic("missing required service");
        return @ptrCast(@alignCast(ptr));
    }

    pub fn on(self: *Context, name: []const u8, call_ctx: *anyopaque, call: *const fn (*anyopaque) void) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const state = try self.allocator.create(ListenState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .ctx = self, .name = name_copy, .call_ctx = call_ctx };
        try self.effect(removeListener, state);
        try self.listeners.append(self.allocator, .{
            .name = name_copy,
            .ctx = call_ctx,
            .call = call,
        });
    }

    pub fn emit(self: *Context, name: []const u8) void {
        var i: usize = 0;
        while (i < self.listeners.items.len) : (i += 1) {
            const listener = self.listeners.items[i];
            if (std.mem.eql(u8, listener.name, name)) listener.call(listener.ctx);
        }
    }

    fn ready(self: *Context, fiber: *Fiber) bool {
        for (fiber.inject) |key| {
            if (!self.services.contains(key)) return false;
        }
        return true;
    }

    fn activate(self: *Context, fiber: *Fiber) !void {
        fiber.active = true;
        const previous = self.applying;
        self.applying = fiber;
        defer self.applying = previous;
        fiber.apply_fn(self) catch |err| {
            fiber.drop();
            return err;
        };
    }

    fn dupeKeys(self: *Context, keys: []const []const u8) ![]const []const u8 {
        const out = try self.allocator.alloc([]const u8, keys.len);
        errdefer self.allocator.free(out);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |key| self.allocator.free(key);
        }
        for (keys) |key| {
            out[done] = try self.allocator.dupe(u8, key);
            done += 1;
        }
        return out;
    }

    fn removeService(state: *anyopaque) void {
        const s: *SetState = @ptrCast(@alignCast(state));
        const ctx = s.ctx;
        if (ctx.services.fetchRemove(s.key)) |_| {
            for (ctx.fibers.items) |fiber| {
                if (!fiber.active or fiber.dropping) continue;
                for (fiber.inject) |key| {
                    if (std.mem.eql(u8, key, s.key)) {
                        fiber.drop();
                        break;
                    }
                }
            }
        }
        if (s.destroy) |destroy| destroy(s.ptr);
        ctx.allocator.free(s.key);
        ctx.allocator.destroy(s);
    }

    fn removeListener(state: *anyopaque) void {
        const s: *ListenState = @ptrCast(@alignCast(state));
        var i: usize = 0;
        while (i < s.ctx.listeners.items.len) {
            const listener = s.ctx.listeners.items[i];
            if (listener.ctx == s.call_ctx and std.mem.eql(u8, listener.name, s.name)) {
                _ = s.ctx.listeners.swapRemove(i);
                break;
            }
            i += 1;
        }
        s.ctx.allocator.free(s.name);
        s.ctx.allocator.destroy(s);
    }
};

const OwnedByte = struct {
    allocator: std.mem.Allocator,
    value: u8,
};

fn destroyOwned(ptr: *anyopaque) void {
    const owned: *OwnedByte = @ptrCast(@alignCast(ptr));
    const allocator = owned.allocator;
    allocator.destroy(owned);
}

fn provideOwned(ctx: *Context) !void {
    const owned = try ctx.allocator.create(OwnedByte);
    owned.* = .{ .allocator = ctx.allocator, .value = 1 };
    try ctx.set("marker", owned, destroyOwned);
}

const CounterBox = struct {
    allocator: std.mem.Allocator,
    n: usize = 0,
};

fn destroyCounterBox(ptr: *anyopaque) void {
    const box: *CounterBox = @ptrCast(@alignCast(ptr));
    const allocator = box.allocator;
    allocator.destroy(box);
}

fn listenBox(ctx: *Context) !void {
    const box = try ctx.allocator.create(CounterBox);
    box.* = .{ .allocator = ctx.allocator };
    try ctx.set("counter", box, destroyCounterBox);
    try ctx.on("tick", box, countBox);
}

fn countBox(ptr: *anyopaque) void {
    const box: *CounterBox = @ptrCast(@alignCast(ptr));
    box.n += 1;
}

fn needsMarker(ctx: *Context) !void {
    _ = ctx.require(OwnedByte, "marker");
    const flag = try ctx.allocator.create(OwnedByte);
    flag.* = .{ .allocator = ctx.allocator, .value = 2 };
    try ctx.set("child", flag, destroyOwned);
}

test "dispose removes a service and its listeners" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();

    const marker = Plugin{ .name = "marker", .apply = provideOwned };
    const listener = Plugin{ .name = "listener", .inject = &.{"marker"}, .apply = listenBox };
    const marker_fiber = try ctx.mount("marker", marker);
    const listener_fiber = try ctx.mount("listener", listener);
    try std.testing.expect(marker_fiber.active);
    try std.testing.expect(listener_fiber.active);

    ctx.emit("tick");
    const box = ctx.require(CounterBox, "counter");
    try std.testing.expectEqual(@as(usize, 1), box.n);

    marker_fiber.dispose();
    try std.testing.expect(ctx.get("marker") == null);
    try std.testing.expect(ctx.get("counter") == null);
    try std.testing.expect(!listener_fiber.active);

    ctx.emit("tick");
    try std.testing.expectEqual(@as(usize, 0), ctx.listeners.items.len);
}

test "a plugin stays inactive until its coeffect appears" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();

    const child = Plugin{ .name = "child", .inject = &.{"marker"}, .apply = needsMarker };
    const child_fiber = try ctx.mount("child", child);
    try std.testing.expect(!child_fiber.active);
    try std.testing.expect(ctx.get("child") == null);

    const parent = Plugin{ .name = "marker", .apply = provideOwned };
    _ = try ctx.mount("marker", parent);
    try std.testing.expect(child_fiber.active);
    try std.testing.expect(ctx.get("child") != null);
}

test "duplicate loader ids are rejected" {
    const gpa = std.testing.allocator;
    var ctx = Context.init(gpa);
    defer ctx.deinit();
    const plugin = Plugin{ .name = "marker", .apply = provideOwned };
    _ = try ctx.mount("marker", plugin);
    try std.testing.expectError(error.DuplicateId, ctx.mount("marker", plugin));
}
