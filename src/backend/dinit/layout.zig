//! Where dinit services live: service names, generation targets per scope and tier, lookup
//! order and the directory the boot service reads enabled services from.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const name_mod = @import("../../unit/name.zig");

pub const Dirs = profile.BackendDirs;

/// dinit parses `name@argument` as a template instance, so an instance is flattened to
/// `name-argument`; characters outside dinit's name alphabet become `_`.
pub fn serviceName(gpa: Allocator, name: name_mod.Name) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, name.prefix);
    if (name.isInstance()) {
        try out.append(gpa, '-');
        for (name.instance.?) |c| try out.append(gpa, if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '_');
    }
    return out.toOwnedSlice(gpa);
}

/// Replaces a leading `~/` (`~/.config/` maps to `$XDG_CONFIG_HOME/`).
pub fn expandHome(ctx: *const core.Context, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.cutPrefix(u8, path, "~/.config/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.xdg_config_home, rest });
    if (std.mem.cutPrefix(u8, path, "~/")) |rest| return std.fs.path.join(ctx.gpa, &.{ ctx.home, rest });
    return path;
}

fn personalDir(ctx: *const core.Context, dirs: *const Dirs) Allocator.Error![]const u8 {
    const first = if (dirs.user.len > 0) dirs.user[0] else "~/.config/dinit.d";
    return expandHome(ctx, first);
}

fn isLocal(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "/usr/local/");
}

fn firstOr(list: []const []const u8, fallback: []const u8) []const u8 {
    return if (list.len > 0) list[0] else fallback;
}

fn localOf(list: []const []const u8) ?[]const u8 {
    for (list) |d| if (std.mem.startsWith(u8, d, "/usr/local/")) return d;
    return null;
}

fn writableOf(list: []const []const u8) ?[]const u8 {
    for (list) |d| if (!std.mem.startsWith(u8, d, "/usr/local/")) return d;
    return null;
}

/// Directory that receives the service generated from a unit of `tier` found at `source`.
pub fn generationDir(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope, tier: core.Tier, source: []const u8) Allocator.Error![]const u8 {
    switch (scope) {
        .system => switch (tier) {
            .vendor => {
                if (isLocal(source)) if (localOf(dirs.vendor)) |d| return d;
                return dirs.vendor_write orelse writableOf(dirs.vendor) orelse firstOr(dirs.vendor, firstOr(dirs.admin, "/etc/dinit.d"));
            },
            .runtime => {
                for (dirs.runtime) |d| if (ctx.fs.exists(d)) return d;
                return firstOr(dirs.admin, "/etc/dinit.d");
            },
            .admin, .personal => return firstOr(dirs.admin, "/etc/dinit.d"),
        },
        .user => switch (tier) {
            .vendor => {
                if (isLocal(source)) if (localOf(dirs.user_vendor)) |d| return d;
                return writableOf(dirs.user_vendor) orelse try personalDir(ctx, dirs);
            },
            .admin => return firstOr(dirs.user_admin, try personalDir(ctx, dirs)),
            .runtime, .personal => return personalDir(ctx, dirs),
        },
    }
}

/// Service directories in dinit's own search order, highest priority first.
pub fn lookupDirs(ctx: *const core.Context, dirs: *const Dirs, scope: core.Scope) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (scope) {
        .system => {
            try out.appendSlice(ctx.gpa, dirs.admin);
            try out.appendSlice(ctx.gpa, dirs.runtime);
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

/// Path of the file that defines `service`, or null when no lookup directory holds it.
pub fn locate(ctx: *const core.Context, dirs: *const Dirs, service: []const u8) Allocator.Error!?[]const u8 {
    for (try lookupDirs(ctx, dirs, ctx.scope)) |dir| {
        const path = try std.fs.path.join(ctx.gpa, &.{ dir, service });
        if (ctx.fs.exists(path)) return path;
    }
    return null;
}

/// `waits-for.d` directory named by the boot service; the profile default when the boot
/// service cannot be read or names none.
pub fn bootDir(ctx: *const core.Context, dirs: *const Dirs) Allocator.Error![]const u8 {
    const boot = dirs.boot_target orelse "boot";
    if (try locate(ctx, dirs, boot)) |path| {
        if (ctx.fs.readFileAlloc(ctx.gpa, path, 1 << 16)) |content| {
            if (try waitsForDir(ctx.gpa, std.fs.path.dirname(path) orelse "/", content)) |d| return d;
        } else |_| {}
    }
    return switch (ctx.scope) {
        .system => dirs.enable_dir orelse "/etc/dinit.d/boot.d",
        .user => try expandHome(ctx, dirs.user_enable_dir orelse "~/.config/dinit.d/boot.d"),
    };
}

/// First `waits-for.d` value of a service description, made absolute against `base`.
pub fn waitsForDir(gpa: Allocator, base: []const u8, content: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = std.mem.cutPrefix(u8, line, "waits-for.d") orelse continue;
        const trimmed = std.mem.trimStart(u8, rest, " \t");
        if (trimmed.len == 0 or (trimmed[0] != '=' and trimmed[0] != ':')) continue;
        var value = std.mem.trim(u8, trimmed[1..], " \t");
        if (std.mem.findScalar(u8, value, '#')) |i| value = std.mem.trimEnd(u8, value[0..i], " \t");
        if (value.len == 0) continue;
        if (value[0] == '"' and value.len >= 2 and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        return if (value[0] == '/') try gpa.dupe(u8, value) else try std.fs.path.join(gpa, &.{ base, value });
    }
    return null;
}

const testing = std.testing;

test "instances are flattened into a name without @" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo", try serviceName(a, try name_mod.parse(a, "foo.service")));
    try testing.expectEqualStrings("getty-tty1", try serviceName(a, try name_mod.parse(a, "getty@tty1.service")));
    try testing.expectEqualStrings("wg-quick-wg0", try serviceName(a, try name_mod.parse(a, "wg-quick@wg0.service")));
    try testing.expectEqualStrings("x-a_b", try serviceName(a, try name_mod.parse(a, "x@a:b.service")));
}

test "waits-for.d is found in either assignment form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/etc/dinit.d/boot.d", (try waitsForDir(a, "/usr/lib/dinit.d", "type = internal\nwaits-for.d = /etc/dinit.d/boot.d\n")).?);
    try testing.expectEqualStrings("/etc/dinit.d/boot.d", (try waitsForDir(a, "/usr/lib/dinit.d", "type=internal\nwaits-for.d: /etc/dinit.d/boot.d # users\n")).?);
    try testing.expectEqualStrings("/usr/lib/dinit.d/boot.d", (try waitsForDir(a, "/usr/lib/dinit.d", "waits-for.d = boot.d\n")).?);
    try testing.expect((try waitsForDir(a, "/x", "waits-for = foo\ndepends-on = bar\n")) == null);
}
