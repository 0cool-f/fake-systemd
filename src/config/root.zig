const std = @import("std");

pub const Config = @import("Config.zig");
pub const load = @import("load.zig");

test {
    std.testing.refAllDecls(@This());
}
