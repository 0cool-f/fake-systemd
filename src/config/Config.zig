// SPDX-License-Identifier: GPL-3.0-or-later
//! Effective configuration; `load.zig` fills it from files and the environment.
const std = @import("std");
const Diag = @import("../core/Diag.zig");

const Config = @This();

pub const Translate = enum { lazy, eager };
pub const TimersScheduler = enum { auto, native, builtin };

init: []const u8 = "auto",
profile: []const u8 = "auto",
translate: Translate = .lazy,
timers_scheduler: TimersScheduler = .auto,
/// Systemd unit name (with type suffix) to native service name.
aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
allow: []const []const u8 = &.{},
deny: []const []const u8 = &.{},
/// Set by `FAKE_SYSTEMD_DRY_RUN`.
dry_run: bool = false,
/// Set by `FAKE_SYSTEMD_LOG_LEVEL`; null keeps the caller's default.
log_level: ?Diag.Level = null,
/// First problem that makes the configuration untrustworthy (unreadable or oversized file,
/// malformed `Deny=`); verbs that change anything refuse to run while it is set.
load_error: ?[]const u8 = null,

test "defaults" {
    const config: Config = .{};
    try std.testing.expectEqualStrings("auto", config.init);
    try std.testing.expectEqual(Translate.lazy, config.translate);
    try std.testing.expectEqual(@as(usize, 0), config.aliases.count());
    try std.testing.expect(!config.dry_run);
    try std.testing.expectEqual(@as(?Diag.Level, null), config.log_level);
}
