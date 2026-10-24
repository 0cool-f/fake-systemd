const std = @import("std");

pub const systemctl = @import("systemctl.zig");
pub const journalctl = @import("journalctl.zig");
pub const output = @import("output.zig");

test {
    std.testing.refAllDecls(@This());
    _ = systemctl;
    _ = journalctl;
    _ = output;
}
