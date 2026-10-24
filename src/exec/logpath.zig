// SPDX-License-Identifier: GPL-3.0-or-later
//! Location of the uniform per-unit logs (spec §6.7).
const std = @import("std");
const core = @import("../core/root.zig");

pub const system_root = "/var/log/fake-systemd";

/// Directory holding `current` and the rotated files of `unit_name` in the scope of `ctx`;
/// allocated from `ctx.gpa`, which is an arena.
pub fn logDir(ctx: *const core.Context, unit_name: []const u8) []const u8 {
    return logDirFor(ctx, ctx.scope, unit_name);
}

/// Like `logDir` for an explicit scope.
pub fn logDirFor(ctx: *const core.Context, scope: core.Scope, unit_name: []const u8) []const u8 {
    const result = switch (scope) {
        .system => std.fs.path.join(ctx.gpa, &.{ system_root, unit_name }),
        .user => std.fs.path.join(ctx.gpa, &.{ ctx.xdg_state_home, "fake-systemd/log", unit_name }),
    };
    return result catch @panic("out of memory");
}

/// The directory that holds one log directory per unit.
pub fn logRoot(ctx: *const core.Context, scope: core.Scope) []const u8 {
    return switch (scope) {
        .system => system_root,
        .user => std.fs.path.join(ctx.gpa, &.{ ctx.xdg_state_home, "fake-systemd/log" }) catch @panic("out of memory"),
    };
}

test "system and user locations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "/s");
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var diag: core.Diag = .init(&w, .notice);
    var fs: core.Fs = undefined;
    const sys: core.Context = try .init(arena.allocator(), std.testing.io, &fs, &diag, &env, .system, 0);
    try std.testing.expectEqualStrings("/var/log/fake-systemd/a.service", logDir(&sys, "a.service"));
    try std.testing.expectEqualStrings("/s/fake-systemd/log/a.service", logDirFor(&sys, .user, "a.service"));
    try std.testing.expectEqualStrings("/var/log/fake-systemd", logRoot(&sys, .system));
    const usr: core.Context = try .init(arena.allocator(), std.testing.io, &fs, &diag, &env, .user, 1000);
    try std.testing.expectEqualStrings("/s/fake-systemd/log/a.service", logDir(&usr, "a.service"));
    try std.testing.expectEqualStrings("/s/fake-systemd/log", logRoot(&usr, .user));
}
