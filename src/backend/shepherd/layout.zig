// SPDX-License-Identifier: GPL-3.0-or-later
//! Where Shepherd services live: service names, the `available/` directory that receives
//! generated files, the `init.d/` directory whose links the configuration loads at startup, and
//! the configuration file of each scope.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

pub const default_system_dir = "/etc/shepherd";
pub const default_user_dir = "~/.config/shepherd";
/// Configuration file `shepherd` reads when started by root, and by a user.
pub const system_config = "/etc/shepherd.scm";
pub const user_config = "~/.config/shepherd/init.scm";
/// Present on Guix System, whose services come from the operating-system declaration.
pub const guix_system_marker = "/run/current-system";
pub const scm_suffix = ".scm";

/// An instance becomes `name-instance`.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, name.prefix);
    if (name.isInstance()) {
        try out.append(gpa, '-');
        for (name.instance.?) |c| try out.append(gpa, if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_');
    }
    return out.toOwnedSlice(gpa);
}

pub fn serviceOfFile(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return std.mem.cutSuffix(u8, base, scm_suffix) orelse base;
}

/// Replaces a leading `~/` (`~/.config/` maps to `$XDG_CONFIG_HOME/`).
pub fn expandHome(ctx: *const core.Context, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.cutPrefix(u8, path, "~/.config/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.xdg_config_home, rest });
    if (std.mem.cutPrefix(u8, path, "~/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.home, rest });
    return path;
}

/// Directory of the configuration of `scope`: `/etc/shepherd` or the user's.
pub fn baseDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const u8 {
    return switch (scope) {
        .system => if (dirs.admin.len > 0) dirs.admin[0] else default_system_dir,
        .user => expandHome(ctx, if (dirs.user.len > 0) dirs.user[0] else default_user_dir),
    };
}

/// The one directory that receives generated files.
pub fn availableDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ try baseDir(ctx, dirs, scope), "available" });
}

/// Directory whose files the configuration loads at startup.
pub fn enabledDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ try baseDir(ctx, dirs, scope), "init.d" });
}

pub fn configFile(ctx: *const core.Context, scope: core.Scope) Allocator.Error![]const u8 {
    return switch (scope) {
        .system => system_config,
        .user => expandHome(ctx, user_config),
    };
}

fn fileName(gpa: Allocator, service: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ service, scm_suffix });
}

pub fn availablePath(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ try availableDir(ctx, dirs, ctx.scope), try fileName(ctx.gpa, service) });
}

pub fn enabledPath(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error![]const u8 {
    return std.fs.path.join(ctx.gpa, &.{ try enabledDir(ctx, dirs, ctx.scope), try fileName(ctx.gpa, service) });
}

/// Directories with service files: `available/` and `init.d/`.
pub fn lookupDirs(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const []const u8 {
    const out = try ctx.gpa.alloc([]const u8, 2);
    out[0] = try availableDir(ctx, dirs, scope);
    out[1] = try enabledDir(ctx, dirs, scope);
    return out;
}

/// Path of the file of `service`, or null when no lookup directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    const file = try fileName(ctx.gpa, service);
    for (try lookupDirs(ctx, dirs, ctx.scope)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, file });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

pub fn isGuixSystem(ctx: *const core.Context) bool {
    return ctx.scope == .system and ctx.fs.exists(guix_system_marker);
}

const testing = std.testing;

test "instances become name-instance and files map back to services" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty-tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("foo", serviceOfFile("/etc/shepherd/available/foo.scm"));
}
