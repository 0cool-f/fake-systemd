// SPDX-License-Identifier: GPL-3.0-or-later
//! Where 66 services live: names, the directories frontend files are generated into and looked
//! up in, and where 66 keeps the result of parsing a frontend file.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

/// Working directory of 66 for the system and, relative to `$HOME`, for a user; the compile-time
/// defaults of `system-dir` and `user-dir`.
pub const system_dir = "/var/lib/66";
pub const user_dir = ".66";

/// Name of a unit's service. `foo@bar` names the instance `bar` of the template `foo@` for 66,
/// so an instance is flattened to `foo-bar`, and characters outside `[A-Za-z0-9._-]` become `_`.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try appendSafe(gpa, &out, name.prefix);
    if (name.isInstance()) {
        try out.append(gpa, '-');
        try appendSafe(gpa, &out, name.instance.?);
    }
    return out.toOwnedSlice(gpa);
}

fn appendSafe(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |c| try out.append(gpa, if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_');
}

/// Replaces a leading `~/` with the home directory.
pub fn expandHome(ctx: *const core.Context, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.cutPrefix(u8, path, "~/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.home, rest });
    return path;
}

fn personalDir(ctx: *const core.Context, dirs: *const Dirs) Allocator.Error![]const u8 {
    return expandHome(ctx, if (dirs.user.len > 0) dirs.user[0] else "~/.66/service");
}

fn firstOr(list: []const []const u8, fallback: []const u8) []const u8 {
    return if (list.len > 0) list[0] else fallback;
}

/// Directory that receives the frontend file generated from a unit of `tier`.
pub fn generationDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope, tier: core.Tier) Allocator.Error![]const u8 {
    switch (scope) {
        .system => return switch (tier) {
            .vendor => dirs.vendor_write orelse firstOr(dirs.vendor, firstOr(dirs.admin, "/etc/66/service")),
            .runtime, .admin, .personal => firstOr(dirs.admin, "/etc/66/service"),
        },
        .user => {
            // An account other than root cannot write the system directories of user services.
            if (ctx.uid != 0) return personalDir(ctx, dirs);
            return switch (tier) {
                .vendor => firstOr(dirs.user_vendor, try personalDir(ctx, dirs)),
                .admin => firstOr(dirs.user_admin, try personalDir(ctx, dirs)),
                .runtime, .personal => try personalDir(ctx, dirs),
            };
        },
    }
}

/// Directories 66 reads frontend files from, the one it prefers first.
pub fn lookupDirs(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (scope) {
        .system => {
            try out.appendSlice(ctx.gpa, dirs.admin);
            try out.appendSlice(ctx.gpa, dirs.vendor);
        },
        .user => {
            try out.append(ctx.gpa, try personalDir(ctx, dirs));
            try out.appendSlice(ctx.gpa, dirs.user_admin);
            try out.appendSlice(ctx.gpa, dirs.user_vendor);
        },
    }
    return out.toOwnedSlice(ctx.gpa);
}

/// Path of the frontend file of `service`, or null when no lookup directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (try lookupDirs(ctx, dirs, ctx.scope)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        const st = ctx.fs.stat(path) catch continue;
        if (st.kind == .file) return path;
    }
    return null;
}

/// `<working dir>/system`, where 66 keeps trees and parsed services.
pub fn stateRoot(ctx: *const core.Context) Allocator.Error![]const u8 {
    return switch (ctx.scope) {
        .system => std.fs.path.join(ctx.gpa, &.{ system_dir, "system" }),
        .user => std.fs.path.join(ctx.gpa, &.{ ctx.home, user_dir, "system" }),
    };
}

/// Link 66 creates for a parsed service; absent while the service was never parsed.
pub fn parsedLink(ctx: *const core.Context, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ try stateRoot(ctx), ".resolve", "service", service });
}

/// Resolve file of a parsed service.
pub fn resolvePath(ctx: *const core.Context, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ try stateRoot(ctx), "service", "svc", service, ".resolve", service });
}

/// Service a generated file belongs to: its name.
pub fn serviceOfFile(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

const testing = std.testing;

test "instances are flattened and unusual characters replaced" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty-tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("wg-quick-wg0", try serviceName(a, try name_mod.parse(a, "wg-quick@wg0.service")));
    try testing.expectEqualStrings("x-a_b", try serviceName(a, try name_mod.parse(a, "x@a:b.service")));
}

test "the generated file is named after the service" {
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/66/service/foo"));
}
