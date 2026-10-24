//! State-directory layout for one backend and scope (§7.1, §8.2).
const std = @import("std");
const types = @import("../core/types.zig");

const Layout = @This();

pub const system_state_dir = "/var/lib/fake-systemd";

pub const BackupKind = enum {
    fsnew,
    fssave,

    pub fn suffix(k: BackupKind) []const u8 {
        return switch (k) {
            .fsnew => ".fsnew",
            .fssave => ".fssave",
        };
    }
};

state_dir: []const u8,
backend: []const u8,

/// `xdg_state_home` is only used in user scope.
pub fn init(gpa: std.mem.Allocator, scope: types.Scope, xdg_state_home: []const u8, backend: []const u8) !Layout {
    return .{
        .state_dir = switch (scope) {
            .system => system_state_dir,
            .user => try std.fs.path.join(gpa, &.{ xdg_state_home, "fake-systemd" }),
        },
        .backend = backend,
    };
}

pub fn indexPath(l: Layout, gpa: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(gpa, &.{ l.state_dir, l.backend, "index" });
}

pub fn lockPath(l: Layout, gpa: std.mem.Allocator) ![]u8 {
    return std.fs.path.join(gpa, &.{ l.state_dir, l.backend, "index.lock" });
}

/// `<state>/backup/<backend>/<original path>.fsnew|.fssave`; `original_abs` must be absolute.
pub fn backupPath(l: Layout, gpa: std.mem.Allocator, original_abs: []const u8, kind: BackupKind) ![]u8 {
    std.debug.assert(std.fs.path.isAbsolute(original_abs));
    const rel = std.mem.trimStart(u8, original_abs, "/");
    return std.fmt.allocPrint(gpa, "{s}/backup/{s}/{s}{s}", .{ l.state_dir, l.backend, rel, kind.suffix() });
}

test "system layout" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l: Layout = try .init(a, .system, "/ignored", "dinit");
    try std.testing.expectEqualStrings("/var/lib/fake-systemd/dinit/index", try l.indexPath(a));
    try std.testing.expectEqualStrings("/var/lib/fake-systemd/dinit/index.lock", try l.lockPath(a));
    try std.testing.expectEqualStrings(
        "/var/lib/fake-systemd/backup/dinit/etc/dinit.d/foo.fsnew",
        try l.backupPath(a, "/etc/dinit.d/foo", .fsnew),
    );
}

test "user layout" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l: Layout = try .init(a, .user, "/home/u/.local/state", "dinit");
    try std.testing.expectEqualStrings("/home/u/.local/state/fake-systemd/dinit/index", try l.indexPath(a));
    try std.testing.expectEqualStrings(
        "/home/u/.local/state/fake-systemd/backup/dinit/home/u/.config/dinit.d/foo.fssave",
        try l.backupPath(a, "/home/u/.config/dinit.d/foo", .fssave),
    );
}
