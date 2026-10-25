// SPDX-License-Identifier: GPL-3.0-or-later
//! Executable extraction shared by all backends (§6.3): wrapper stripping, interpreter handling
//! and path normalization. A backend supplies the command words of a native service; this
//! module reduces them to the program that actually runs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../core/Fs.zig");
const execline = @import("../unit/execline.zig");

const max_depth = 8;

const Wrapper = struct {
    name: []const u8,
    /// Options that consume the following word.
    valued: []const []const u8 = &.{},
    /// Positional words before the wrapped command.
    positional: u8 = 0,
};

const wrappers = [_]Wrapper{
    .{ .name = "env", .valued = &.{ "-u", "-C", "-S", "--unset", "--chdir" } },
    .{ .name = "nice", .valued = &.{ "-n", "--adjustment" } },
    .{ .name = "ionice", .valued = &.{ "-c", "-n", "-p", "-P", "-u", "--class", "--classdata" } },
    .{ .name = "chpst", .valued = &.{ "-u", "-U", "-e", "-m", "-d", "-o", "-p", "-f", "-c", "-r", "-/", "-C", "-n", "-l", "-L", "-b" } },
    .{ .name = "s6-setuidgid", .positional = 1 },
    .{ .name = "s6-envdir", .positional = 1 },
    .{ .name = "s6-envuidgid", .valued = &.{"-D"}, .positional = 1 },
    .{ .name = "s6-applyuidgid", .valued = &.{ "-u", "-g", "-G" } },
    .{ .name = "s6-softlimit", .valued = &.{ "-a", "-c", "-d", "-f", "-l", "-m", "-o", "-p", "-r", "-s", "-t" } },
    .{ .name = "su-exec", .positional = 1 },
};

const setpriv_flags = [_][]const u8{
    "--no-new-privs", "--init-groups", "--clear-groups", "--keep-groups", "--reset-env", "--list-caps", "--dump",
};

const shells = [_][]const u8{ "sh", "bash", "dash", "ash", "zsh", "ksh" };
const interpreters = [_][]const u8{ "python", "perl", "ruby", "node", "nodejs", "lua", "luajit", "php", "bun" };

fn inList(list: []const []const u8, word: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, word)) return true;
    return false;
}

fn isInterpreter(base: []const u8) bool {
    for (interpreters) |i| if (std.mem.startsWith(u8, base, i)) return true;
    return false;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.findScalar(u8, word, '=') orelse return false;
    return eq > 0 and word[0] != '-';
}

fn skipOptions(w: []const []const u8, valued: []const []const u8, assignments: bool) []const []const u8 {
    var rest = w;
    while (rest.len > 0) {
        const word = rest[0];
        if (std.mem.eql(u8, word, "--")) return rest[1..];
        if (assignments and isAssignment(word)) {
            rest = rest[1..];
        } else if (word.len > 1 and word[0] == '-') {
            rest = if (inList(valued, word) and rest.len > 1) rest[2..] else rest[1..];
        } else break;
    }
    return rest;
}

fn skipSetpriv(w: []const []const u8) []const []const u8 {
    var rest = w;
    while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "--")) {
        const word = rest[0];
        const takes_value = std.mem.findScalar(u8, word, '=') == null and !inList(&setpriv_flags, word);
        rest = if (takes_value and rest.len > 1) rest[2..] else rest[1..];
    }
    return rest;
}

fn optionValue(w: []const []const u8, long: []const u8, short: []const u8) ?[]const u8 {
    for (w, 0..) |word, i| {
        if (std.mem.eql(u8, word, "--")) return null;
        if (std.mem.eql(u8, word, long) or std.mem.eql(u8, word, short)) {
            return if (i + 1 < w.len) w[i + 1] else null;
        }
        if (std.mem.startsWith(u8, word, long) and word.len > long.len and word[long.len] == '=') return word[long.len + 1 ..];
    }
    return null;
}

fn afterDoubleDash(w: []const []const u8) ?[]const []const u8 {
    for (w, 0..) |word, i| if (std.mem.eql(u8, word, "--")) return w[i + 1 ..];
    return null;
}

/// First argument that is not an option.
fn firstOperand(w: []const []const u8) ?[]const u8 {
    for (w) |word| {
        if (word.len > 1 and word[0] == '-') continue;
        return word;
    }
    return null;
}

/// Program that runs when `words` is executed, or null when nothing can be determined.
pub fn commandExecutable(gpa: Allocator, words: []const []const u8) Allocator.Error!?[]const u8 {
    return strip(gpa, words, 0);
}

fn strip(gpa: Allocator, words: []const []const u8, depth: usize) Allocator.Error!?[]const u8 {
    var w = words;
    var steps: usize = 0;
    while (w.len > 0 and steps < max_depth * 2) : (steps += 1) {
        const base = std.fs.path.basename(w[0]);
        const args = w[1..];
        if (std.mem.eql(u8, base, "exec")) {
            w = skipOptions(args, &.{"-a"}, false);
            continue;
        }
        if (findWrapper(base)) |spec| {
            w = skipOptions(args, spec.valued, std.mem.eql(u8, spec.name, "env"));
            w = w[@min(w.len, spec.positional)..];
            continue;
        }
        if (std.mem.eql(u8, base, "setpriv")) {
            w = skipSetpriv(args);
            continue;
        }
        if (std.mem.eql(u8, base, "start-stop-daemon")) {
            if (optionValue(args, "--exec", "-x")) |exe| return exe;
            w = afterDoubleDash(args) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, base, "runuser")) {
            if (optionValue(args, "--command", "-c")) |cmd| return stripShellString(gpa, cmd, depth);
            w = skipOptions(args, &.{ "-u", "-g", "-G", "-l", "-s", "--user", "--group" }, false);
            continue;
        }
        if (inList(&shells, base)) {
            if (optionValue(args, "--command", "-c")) |cmd| return stripShellString(gpa, cmd, depth);
            return firstOperand(args) orelse w[0];
        }
        if (isInterpreter(base)) return firstOperand(args) orelse w[0];
        return w[0];
    }
    return null;
}

fn findWrapper(base: []const u8) ?Wrapper {
    for (wrappers) |wr| if (std.mem.eql(u8, wr.name, base)) return wr;
    return null;
}

fn stripShellString(gpa: Allocator, cmd: []const u8, depth: usize) Allocator.Error!?[]const u8 {
    if (depth >= max_depth) return null;
    const inner = execline.splitWords(gpa, cmd) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return strip(gpa, inner, depth + 1);
}

/// Resolves symlinks inside the filesystem root so `/bin/foo` and `/usr/bin/foo` coincide on
/// merged-`/usr` systems. Relative or unresolvable paths are returned unchanged.
pub fn normalizePath(fs: Fs, gpa: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (path.len == 0 or path[0] != '/') return path;
    return fs.realpath(gpa, path) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return path,
    };
}

/// `commandExecutable` followed by `normalizePath`.
pub fn normalizedExecutable(fs: Fs, gpa: Allocator, words: []const []const u8) Allocator.Error!?[]const u8 {
    const exe = (try commandExecutable(gpa, words)) orelse return null;
    return try normalizePath(fs, gpa, exe);
}

const testing = std.testing;

fn expectExe(expected: ?[]const u8, words: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try commandExecutable(arena.allocator(), words);
    if (expected) |e| {
        try testing.expectEqualStrings(e, got.?);
    } else try testing.expect(got == null);
}

test "plain command" {
    try expectExe("/usr/bin/foo", &.{ "/usr/bin/foo", "--bar" });
}

test "env, nice and chpst wrappers" {
    try expectExe("/usr/bin/foo", &.{ "env", "A=1", "-u", "B", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "nice", "-n", "5", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "ionice", "-c", "3", "nice", "-n5", "exec", "/usr/bin/foo", "x" });
    try expectExe("/usr/bin/foo", &.{ "chpst", "-u", "svc:grp", "-e", "env", "/usr/bin/foo" });
}

test "positional wrappers" {
    try expectExe("/usr/bin/foo", &.{ "s6-setuidgid", "svc", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "s6-envdir", "-I", "/etc/env", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "su-exec", "svc:grp", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "s6-softlimit", "-m", "1000", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "s6-envuidgid", "-i", "-D", "65534:65534:", "svc", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "s6-applyuidgid", "-u", "1500", "-g", "1500", "-G", "1501,1502", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "setpriv", "--reuid", "1000", "--no-new-privs", "--regid=2", "/usr/bin/foo" });
}

test "start-stop-daemon and runuser" {
    try expectExe("/usr/sbin/foo", &.{ "start-stop-daemon", "--start", "--exec", "/usr/sbin/foo", "--", "-x" });
    try expectExe("/usr/sbin/foo", &.{ "start-stop-daemon", "-S", "--exec=/usr/sbin/foo" });
    try expectExe("/usr/sbin/foo", &.{ "start-stop-daemon", "--start", "--pidfile", "p", "--", "/usr/sbin/foo", "a" });
    try expectExe("/usr/bin/foo", &.{ "runuser", "-u", "svc", "--", "/usr/bin/foo" });
    try expectExe("/usr/bin/foo", &.{ "runuser", "-l", "svc", "-c", "exec /usr/bin/foo --x" });
}

test "shells and interpreters resolve to the script" {
    try expectExe("/usr/bin/foo", &.{ "sh", "-c", "exec nice -n 3 /usr/bin/foo --daemon" });
    try expectExe("/opt/foo/run.sh", &.{ "/bin/sh", "/opt/foo/run.sh" });
    try expectExe("/usr/bin/foo.py", &.{ "/usr/bin/python3", "-u", "/usr/bin/foo.py" });
    try expectExe("/usr/bin/perl", &.{"/usr/bin/perl"});
    try expectExe(null, &.{ "sh", "-c", "'unterminated" });
}

test "normalizePath resolves symlinks inside the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try fs.makePath("/usr/bin");
    try fs.writeFileAtomic("/usr/bin/foo", "x", 0o755);
    try fs.symLink("usr/bin", "/bin");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/usr/bin/foo", try normalizePath(fs, arena.allocator(), "/bin/foo"));
    try testing.expectEqualStrings("/nope/x", try normalizePath(fs, arena.allocator(), "/nope/x"));
    try testing.expectEqualStrings("rel", try normalizePath(fs, arena.allocator(), "rel"));
}
