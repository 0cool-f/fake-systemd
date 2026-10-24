//! Native-service scan (§6.3, §7.6): iterates service directories and reduces each service to
//! its executable with a per-backend extractor. Results are cached per file: a file is read
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
    /// Some file appeared, disappeared or changed since `previous`.
    changed: bool,
};

fn findPrevious(previous: []const Index.Native, path: []const u8) ?Index.Native {
    for (previous) |p| if (std.mem.eql(u8, p.path, path)) return p;
    return null;
}

pub fn scanCached(gpa: Allocator, fs: Fs, dirs: []const []const u8, extractor: Extractor, previous: []const Index.Native) !Result {
    var entries: std.ArrayList(Index.Native) = .empty;
    var changed = false;
    for (dirs) |dir| {
        const listing = fs.iterateDir(gpa, dir) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        for (listing) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const path = try std.fs.path.join(gpa, &.{ dir, entry.name });
            const fingerprint = hash.fileFingerprint(fs, path);
            if (fingerprint != 0) {
                if (findPrevious(previous, path)) |p| {
                    if (p.file_stat == fingerprint) {
                        try entries.append(gpa, p);
                        continue;
                    }
                }
            }
            changed = true;
            if (try readEntry(gpa, fs, extractor, entry.name, path, fingerprint)) |fresh| try entries.append(gpa, fresh);
        }
    }
    if (entries.items.len != previous.len) changed = true;

    var services: std.ArrayList(interface.NativeService) = .empty;
    for (entries.items) |e| {
        if (e.exec.len == 0) continue;
        try services.append(gpa, .{ .name = e.name, .path = e.path, .exec = e.exec });
    }
    return .{ .services = services.items, .entries = entries.items, .changed = changed };
}

fn readEntry(gpa: Allocator, fs: Fs, extractor: Extractor, name: []const u8, path: []const u8, fingerprint: u64) !?Index.Native {
    const content = fs.readFileAlloc(gpa, path, hash.max_file_size) catch |e| switch (e) {
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
pub fn scanDirs(gpa: Allocator, fs: Fs, dirs: []const []const u8, extractor: Extractor) ![]const interface.NativeService {
    return (try scanCached(gpa, fs, dirs, extractor, &.{})).services;
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

    const found = try scanDirs(a, fs, &.{ "/etc/dinit.d", "/missing" }, commandLine);
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
    const dirs = [_][]const u8{"/etc/dinit.d"};

    const first = try scanCached(a, fs, &dirs, commandLine, &.{});
    try testing.expect(first.changed);
    try testing.expectEqual(@as(usize, 3), first.entries.len);

    const second = try scanCached(a, fs, &dirs, commandLine, first.entries);
    try testing.expect(!second.changed);
    try testing.expectEqual(@as(usize, 1), second.services.len);

    try fs.writeFileAtomic("/etc/dinit.d/baz", "command = /usr/bin/foo\n", 0o644);
    const added = try scanCached(a, fs, &dirs, commandLine, second.entries);
    try testing.expect(added.changed);
    try testing.expectEqual(@as(usize, 2), added.services.len);

    try fs.writeFileAtomic("/etc/dinit.d/baz", "command = /usr/bin/other\n", 0o644);
    const edited = try scanCached(a, fs, &dirs, commandLine, added.entries);
    try testing.expect(edited.changed);
    try testing.expectEqualStrings("/usr/bin/other", edited.services[0].exec);

    try fs.deleteFile("/etc/dinit.d/baz");
    const removed = try scanCached(a, fs, &dirs, commandLine, edited.entries);
    try testing.expect(removed.changed);
    try testing.expectEqual(@as(usize, 1), removed.services.len);
}
