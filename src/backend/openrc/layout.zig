// SPDX-License-Identifier: GPL-3.0-or-later
//! Where OpenRC services live: script names, the init script directories of each scope, the
//! runlevel directories whose symlinks enable a service, and the state directory of a running
//! OpenRC.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

/// Script name of a unit. A template instance becomes `name.instance`, the form OpenRC uses for
/// multiplexed services such as `net.eth0`; `rc-service` and the runlevels take it as any name.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    if (name.isInstance()) return std.fmt.allocPrint(gpa, "{s}.{s}", .{ name.prefix, name.instance.? });
    return gpa.dupe(u8, name.prefix);
}

/// Replaces a leading `~/` (`~/.config/` maps to `$XDG_CONFIG_HOME/`).
pub fn expandHome(ctx: *const core.Context, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.cutPrefix(u8, path, "~/.config/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.xdg_config_home, rest });
    if (std.mem.cutPrefix(u8, path, "~/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.home, rest });
    return path;
}

/// The one directory that receives generated scripts, whatever the tier of the unit.
pub fn generationDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const u8 {
    return switch (scope) {
        .system => if (dirs.admin.len > 0) dirs.admin[0] else "/etc/init.d",
        .user => expandHome(ctx, if (dirs.user.len > 0) dirs.user[0] else "~/.config/rc/init.d"),
    };
}

/// Script directories of `scope`, the places `rc-service` names resolve to.
pub fn lookupDirs(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (scope) {
        .system => try out.appendSlice(ctx.gpa, dirs.admin),
        .user => {
            try out.append(ctx.gpa, try generationDir(ctx, dirs, .user));
            try out.appendSlice(ctx.gpa, dirs.user_admin);
        },
    }
    return out.toOwnedSlice(ctx.gpa);
}

/// Path of the script of `service`, or null when no lookup directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (try lookupDirs(ctx, dirs, ctx.scope)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

/// The runlevel the profile enables services in.
pub fn runlevel(dirs: *const Dirs) []const u8 {
    return dirs.boot_target orelse "default";
}

/// Directory of the runlevel `level`, whose symlinks are the services enabled in it.
pub fn runlevelDir(ctx: *const core.Context, dirs: *const Dirs, level: []const u8) Allocator.Error![]const u8 {
    const base = switch (ctx.scope) {
        .system => dirs.enable_dir orelse "/etc/runlevels",
        .user => try expandHome(ctx, dirs.user_enable_dir orelse "~/.config/rc/runlevels"),
    };
    return std.fs.path.join(ctx.gpa, &.{ base, level });
}

/// State directory of a running OpenRC: `/run/openrc`, or `openrc` in the runtime directory of
/// the user for a user session.
pub fn stateDir(ctx: *const core.Context) Allocator.Error![]const u8 {
    return switch (ctx.scope) {
        .system => "/run/openrc",
        .user => std.fs.path.join(ctx.gpa, &.{ ctx.xdg_runtime_dir, "openrc" }),
    };
}

/// Directories that hold the `version` file of the installed OpenRC.
pub const version_files = [_][]const u8{
    "/usr/libexec/rc/version",
    "/usr/lib/openrc/version",
    "/usr/lib/rc/version",
    "/lib/rc/version",
};

const testing = std.testing;

test "instances become name.instance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty.tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("wg-quick.wg0", try serviceName(a, try name_mod.parse(a, "wg-quick@wg0.service")));
}
