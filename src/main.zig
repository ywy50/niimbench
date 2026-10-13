const std = @import("std");
const niimbench = @import("niimbench");

pub fn main(init: std.process.Init) !void {
    try niimbench.run(init);
}
