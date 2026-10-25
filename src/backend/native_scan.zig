// SPDX-License-Identifier: GPL-3.0-or-later
//! Native-service scan (§6.3, §7.6): iterates service directories and reduces each service to
//! its executable with a per-backend extractor. A service is a file, or a directory holding the
//! command in `NativeScan.entry_file`. Results are cached per service: the command file is read
//! again only when its stat fingerprint differs from the cached entry.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../core/Fs.zig");
const marker = @import("../index/marker.zig");
const hash = @import("../index/hash.zig");
const Index = @import("../index/Index.zig");
const exec_norm = @import("exec_norm.zig");
const interface = @import("interface.zig");

pub const Extractor = interface.Extractor;

pub fn isOwned(content: []const u8) bool {
    return marker.parse(content) != null;
}

pub const Result = struct {
    /// Services with an executable.
    services: []const interface.NativeService,
    /// Cache entries for every scanned file; files without a command or with a marker have an empty `exec`.
    entries: []const Index.Native,
    /// Modification time of every existing scanned directory.
    dirs: []const Index.NativeDir,
    /// Some file appeared, disappeared or changed since `previous`.
    changed: bool,
    /// Some directory mtime differs from `previous_dirs`.
    dirs_changed: bool,
};

/// Number of directory listings made by `scanCached`, for tests that assert unchanged directories are skipped.
pub var list_calls: usize = 0;

fn findPrevious(previous: []const Index.Native, path: []const u8) ?Index.Native {
    for (previous) |p| if (std.mem.eql(u8, p.path, path)) return p;
    return null;
}

fn findPreviousDir(previous: []const Index.NativeDir, path: []const u8) ?Index.NativeDir {
    for (previous) |p| if (std.mem.eql(u8, p.path, path)) return p;
    return null;
}

/// Scans `dirs`. A directory whose mtime equals the one in `previous_dirs` is not listed: its
/// cached entries are kept after a stat check of each file.
pub fn scanCached(
    gpa: Allocator,
    fs: Fs,
    scan: interface.NativeScan,
    previous: []const Index.Native,
    previous_dirs: []const Index.NativeDir,
) !Result {
    var entries: std.ArrayList(Index.Native) = .empty;
    var seen_dirs: std.ArrayList(Index.NativeDir) = .empty;
    var changed = false;
    var dirs_changed = false;
    for (scan.dirs) |dir| {
        const dir_stat = fs.stat(dir) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        const known = findPreviousDir(previous_dirs, dir);
        try seen_dirs.append(gpa, .{ .path = dir, .mtime_ns = dir_stat.mtime_ns });
        if (known == null or known.?.mtime_ns != dir_stat.mtime_ns) dirs_changed = true;
        if (known != null and known.?.mtime_ns == dir_stat.mtime_ns) {
            if (try recheckCached(gpa, fs, scan, dir, previous, &entries)) changed = true;
            continue;
        }
        list_calls += 1;
        const listing = fs.iterateDir(gpa, dir) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        for (listing) |entry| {
            const wanted = if (scan.entry_file != null)
                entry.kind == .directory or entry.kind == .sym_link
            else
                entry.kind == .file or entry.kind == .sym_link;
            if (!wanted) continue;
            const path = try std.fs.path.join(gpa, &.{ dir, entry.name });
            const probe = try probePath(gpa, scan, path);
            const fingerprint = hash.fileFingerprint(fs, probe);
            if (fingerprint == 0 and scan.entry_file != null) continue;
            if (fingerprint != 0) {
                if (findPrevious(previous, path)) |p| {
                    if (p.file_stat == fingerprint) {
                        try entries.append(gpa, p);
                        continue;
                    }
                }
            }
            changed = true;
            if (try readEntry(gpa, fs, scan.extractor, entry.name, path, probe, fingerprint)) |fresh| try entries.append(gpa, fresh);
        }
    }
    if (entries.items.len != previous.len) changed = true;

    var services: std.ArrayList(interface.NativeService) = .empty;
    for (entries.items) |e| {
        if (e.exec.len == 0) continue;
        try services.append(gpa, .{ .name = e.name, .path = e.path, .exec = e.exec });
    }
    return .{
        .services = services.items,
        .entries = entries.items,
        .dirs = seen_dirs.items,
        .changed = changed,
        .dirs_changed = dirs_changed or seen_dirs.items.len != previous_dirs.len,
    };
}

/// Appends the cached entries of an unlisted directory whose file fingerprint is unchanged and
/// re-reads the others. Returns true when any file changed or vanished.
fn recheckCached(gpa: Allocator, fs: Fs, scan: interface.NativeScan, dir: []const u8, previous: []const Index.Native, entries: *std.ArrayList(Index.Native)) !bool {
    const anchor = try std.fs.path.join(gpa, &.{ dir, "x" });
    const base = std.fs.path.dirname(anchor).?;
    var changed = false;
    for (previous) |p| {
        const parent = std.fs.path.dirname(p.path) orelse continue;
        if (!std.mem.eql(u8, parent, base)) continue;
        const probe = try probePath(gpa, scan, p.path);
        const fingerprint = hash.fileFingerprint(fs, probe);
        if (fingerprint != 0 and fingerprint == p.file_stat) {
            try entries.append(gpa, p);
            continue;
        }
        changed = true;
        if (try readEntry(gpa, fs, scan.extractor, p.name, p.path, probe, fingerprint)) |fresh| try entries.append(gpa, fresh);
    }
    return changed;
}

/// File that holds the command of the service at `path`.
fn probePath(gpa: Allocator, scan: interface.NativeScan, path: []const u8) Allocator.Error![]const u8 {
    const file = scan.entry_file orelse return path;
    return std.fs.path.join(gpa, &.{ path, file });
}

fn readEntry(gpa: Allocator, fs: Fs, extractor: Extractor, name: []const u8, path: []const u8, probe: []const u8, fingerprint: u64) !?Index.Native {
    const content = fs.readFileAlloc(gpa, probe, hash.max_file_size) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return null,
    };
    var exec: []const u8 = "";
    if (!isOwned(content)) {
        if (try extractor(gpa, content)) |words| {
            if (try exec_norm.normalizedExecutable(fs, gpa, words)) |exe| exec = exe;
        }
    }
    return .{ .name = name, .path = path, .file_hash = hash.ofBytes(content), .file_stat = fingerprint, .exec = exec };
}

/// Uncached scan.
pub fn scanDirs(gpa: Allocator, fs: Fs, scan: interface.NativeScan) ![]const interface.NativeService {
    return (try scanCached(gpa, fs, scan, &.{}, &.{})).services;
}

const testing = std.testing;
const execline = @import("../unit/execline.zig");

fn commandLine(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    const prefix = "command = ";
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        return execline.splitWords(gpa, line[prefix.len..]) catch return null;
    }
    return null;
}

fn fixture(fs: Fs, a: Allocator) !void {
    try fs.makePath("/usr/bin");
    try fs.writeFileAtomic("/usr/bin/foo", "x", 0o755);
    try fs.symLink("usr/bin", "/bin");
    try fs.makePath("/etc/dinit.d");
    try fs.writeFileAtomic("/etc/dinit.d/foo", "command = env A=1 /bin/foo -x\n", 0o644);
    try fs.writeFileAtomic("/etc/dinit.d/none", "type = internal\n", 0o644);
    const owned = try marker.compose(a, "bar.service", "/usr/lib/systemd/system/bar.service", 1, "fake-systemd 0.1.0 t/1", "command = /usr/bin/bar\n");
    try fs.writeFileAtomic("/etc/dinit.d/bar", owned, 0o644);
}

test "scan extracts executables and skips owned and command-less files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fixture(fs, a);

    const found = try scanDirs(a, fs, .{ .dirs = &.{ "/etc/dinit.d", "/missing" }, .extractor = commandLine });
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("foo", found[0].name);
    try testing.expectEqualStrings("/etc/dinit.d/foo", found[0].path);
    try testing.expectEqualStrings("/usr/bin/foo", found[0].exec);
}

test "cached scan reuses unchanged entries and notices additions, edits and removals" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fixture(fs, a);
    const scan: interface.NativeScan = .{ .dirs = &.{"/etc/dinit.d"}, .extractor = commandLine };

    const first = try scanCached(a, fs, scan, &.{}, &.{});
    try testing.expect(first.changed);
    try testing.expectEqual(@as(usize, 3), first.entries.len);

    const listed = list_calls;
    const second = try scanCached(a, fs, scan, first.entries, first.dirs);
    try testing.expect(!second.changed);
    try testing.expect(!second.dirs_changed);
    try testing.expectEqual(listed, list_calls);
    try testing.expectEqual(@as(usize, 1), second.services.len);

    try fs.writeFileAtomic("/etc/dinit.d/baz", "command = /usr/bin/foo\n", 0o644);
    const added = try scanCached(a, fs, scan, second.entries, second.dirs);
    try testing.expect(added.changed);
    try testing.expectEqual(@as(usize, 2), added.services.len);

    try fs.writeFileAtomic("/etc/dinit.d/baz", "command = /usr/bin/other\n", 0o644);
    const edited = try scanCached(a, fs, scan, added.entries, added.dirs);
    try testing.expect(edited.changed);
    try testing.expectEqualStrings("/usr/bin/other", edited.services[0].exec);

    try fs.deleteFile("/etc/dinit.d/baz");
    const removed = try scanCached(a, fs, scan, edited.entries, edited.dirs);
    try testing.expect(removed.changed);
    try testing.expectEqual(@as(usize, 1), removed.services.len);
}

fn runLine(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    const prefix = "exec ";
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) found = line[prefix.len..];
    }
    return execline.splitWords(gpa, found orelse return null) catch return null;
}

test "service directories are scanned through their command file and cached on its fingerprint" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try fs.makePath("/usr/bin");
    try fs.writeFileAtomic("/usr/bin/foo", "x", 0o755);
    try fs.makePath("/etc/sv/foo");
    try fs.makePath("/etc/sv/bar");
    try fs.writeFileAtomic("/etc/sv/foo/run", "#!/bin/sh\nexec /usr/bin/foo\n", 0o755);
    try fs.makePath("/etc/sv/empty");
    try fs.writeFileAtomic("/etc/sv/stray-file", "exec /usr/bin/foo\n", 0o644);
    const owned = try marker.compose(a, "bar.service", "/usr/lib/systemd/system/bar.service", 1, "fake-systemd 0.1.0 t/1", "#!/bin/sh\nexec /usr/bin/bar\n");
    try fs.writeFileAtomic("/etc/sv/bar/run", owned, 0o755);
    const scan: interface.NativeScan = .{ .dirs = &.{"/etc/sv"}, .extractor = runLine, .entry_file = "run" };

    const first = try scanCached(a, fs, scan, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), first.services.len);
    try testing.expectEqualStrings("foo", first.services[0].name);
    try testing.expectEqualStrings("/etc/sv/foo", first.services[0].path);
    try testing.expectEqualStrings("/usr/bin/foo", first.services[0].exec);

    const second = try scanCached(a, fs, scan, first.entries, first.dirs);
    try testing.expect(!second.changed);

    try fs.writeFileAtomic("/etc/sv/foo/run", "#!/bin/sh\nexec /usr/bin/foo --other\n", 0o755);
    const edited = try scanCached(a, fs, scan, second.entries, second.dirs);
    try testing.expect(edited.changed);
    try testing.expectEqual(@as(usize, 1), edited.services.len);
}
