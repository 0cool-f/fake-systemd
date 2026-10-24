// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");

pub const kind = @import("kind.zig");
pub const init = @import("init.zig");
pub const osrelease = @import("osrelease.zig");
pub const profile = @import("profile.zig");

pub const InitKind = kind.InitKind;

test {
    std.testing.refAllDecls(@This());
    _ = kind;
    _ = init;
    _ = osrelease;
    _ = profile;
}
