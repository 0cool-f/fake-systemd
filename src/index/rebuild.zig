//! Rebuilds index entries by scanning service directories for markers (§7.7).
const std = @import("std");
const Fs = @import("../core/Fs.zig");
const Diag = @import("../core/Diag.zig");
const types = @import("../core/types.zig");
const hash = @import("hash.zig");
const marker = @import("marker.zig");
const Index = @import("Index.zig");

pub const ScanDir = struct {
    path: []const u8,
    tier: types.Tier,
};

pub const Options = struct {
    scope: types.Scope,
    dirs: []const ScanDir,
};

/// Adds one `managed` unit per marker found: a regular file with a leading marker block, or a
/// subdirectory with `fake-systemd.meta`. The unit name is the recorded `Unit` field.
/// Recorded body hashes become `out_hash`, so later user edits stay detectable; `src_stat` is 0.
pub fn rebuild(arena: std.mem.Allocator, fs: Fs, diag: *Diag, index: *Index, opts: Options) !void {
    for (opts.dirs) |dir| {
        const entries = fs.iterateDir(arena, dir.path) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                diag.warn("cannot scan {s}: {t}", .{ dir.path, e });
                continue;
            },
        };
        for (entries) |entry| {
            const path = try std.fs.path.join(arena, &.{ dir.path, entry.name });
            switch (entry.kind) {
                .file => try addFile(arena, fs, diag, index, opts.scope, dir.tier, path),
                .directory => try addMetaDir(arena, fs, diag, index, opts.scope, dir.tier, path),
                else => {},
            }
        }
    }
}

fn readSmall(arena: std.mem.Allocator, fs: Fs, diag: *Diag, path: []const u8) !?[]u8 {
    return fs.readFileAlloc(arena, path, hash.max_file_size) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FileNotFound => return null,
        else => {
            diag.info("skipping {s} during rebuild: {t}", .{ path, e });
            return null;
        },
    };
}

fn addEntry(
    arena: std.mem.Allocator,
    index: *Index,
    scope: types.Scope,
    tier: types.Tier,
    unit: []const u8,
    source_hash: u64,
    generator: []const u8,
    file: Index.FileEntry,
) !void {
    if (index.findUnit(unit)) |existing| {
        const files = try arena.alloc(Index.FileEntry, existing.files.len + 1);
        @memcpy(files[0..existing.files.len], existing.files);
        files[existing.files.len] = file;
        existing.files = files;
        return;
    }
    const files = try arena.alloc(Index.FileEntry, 1);
    files[0] = file;
    try index.putUnit(arena, .{
        .name = try arena.dupe(u8, unit),
        .scope = scope,
        .tier = tier,
        .state = .managed,
        .src_hash = source_hash,
        .src_stat = 0,
        .files = files,
        .generator_version = marker.generatorVersion(generator),
    });
}

fn addFile(arena: std.mem.Allocator, fs: Fs, diag: *Diag, index: *Index, scope: types.Scope, tier: types.Tier, path: []const u8) !void {
    const content = try readSmall(arena, fs, diag, path) orelse return;
    const parsed = marker.parse(content) orelse return;
    const m = parsed.marker;
    try addEntry(arena, index, scope, tier, m.unit, m.source_hash, m.generator, .{ .path = path, .out_hash = m.body_hash, .stat = 0 });
}

fn addMetaDir(arena: std.mem.Allocator, fs: Fs, diag: *Diag, index: *Index, scope: types.Scope, tier: types.Tier, dir: []const u8) !void {
    const meta_path = try std.fs.path.join(arena, &.{ dir, marker.meta_name });
    const content = try readSmall(arena, fs, diag, meta_path) orelse return;
    const meta = try marker.parseMeta(arena, content) orelse {
        diag.info("ignoring malformed {s}", .{meta_path});
        return;
    };
    for (meta.bodies) |b| {
        const path = try std.fs.path.join(arena, &.{ dir, b.path });
        try addEntry(arena, index, scope, tier, meta.unit, meta.source_hash, meta.generator, .{ .path = path, .out_hash = b.hash, .stat = 0 });
    }
    // The meta file is itself a generated file; its hash covers its whole content.
    try addEntry(arena, index, scope, tier, meta.unit, meta.source_hash, meta.generator, .{
        .path = meta_path,
        .out_hash = hash.ofBytes(content),
        .stat = 0,
    });
}

const testing = std.testing;

fn writeMarked(fs: Fs, arena: std.mem.Allocator, path: []const u8, source: []const u8, body: []const u8) !void {
    const content = try marker.compose(arena, std.fs.path.basename(source), source, 0xabc, "fake-systemd 0.1.0 dinit/1", body);
    try fs.makePath(std.fs.path.dirname(path).?);
    try fs.writeFileAtomic(path, content, 0o644);
}

test "rebuild finds marked files and ignores native ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try writeMarked(fs, a, "/etc/dinit.d/foo", "/etc/systemd/system/foo.service", "body\n");
    try writeMarked(fs, a, "/usr/lib/dinit.d/bar", "/usr/lib/systemd/system/bar.service", "bar\n");
    try fs.writeFileAtomic("/etc/dinit.d/native", "type = process\n", 0o644);
    try fs.makePath("/etc/dinit.d/subdir");

    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var idx: Index = .init("dinit", 1);
    try rebuild(a, fs, &diag, &idx, .{ .scope = .system, .dirs = &.{
        .{ .path = "/etc/dinit.d", .tier = .admin },
        .{ .path = "/usr/lib/dinit.d", .tier = .vendor },
        .{ .path = "/does/not/exist", .tier = .runtime },
    } });
    try testing.expectEqual(@as(usize, 2), idx.units.items.len);
    const foo = idx.findUnit("foo.service").?;
    try testing.expectEqual(types.Tier.admin, foo.tier);
    try testing.expectEqual(Index.State.managed, foo.state);
    try testing.expectEqual(@as(u64, 0xabc), foo.src_hash);
    try testing.expectEqualStrings("0.1.0", foo.generator_version);
    try testing.expectEqualStrings("/etc/dinit.d/foo", foo.files[0].path);
    try testing.expectEqual(hash.bodyHash("body\n"), foo.files[0].out_hash);
    try testing.expectEqual(types.Tier.vendor, idx.findUnit("bar.service").?.tier);
}

test "rebuild keeps the recorded body hash of a hand-edited file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try writeMarked(fs, a, "/d/foo", "/s/foo.service", "orig\n");
    const content = try fs.readFileAlloc(a, "/d/foo", 4096);
    try fs.writeFileAtomic("/d/foo", try std.mem.concat(a, u8, &.{ content, "edit\n" }), 0o644);
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var idx: Index = .init("dinit", 1);
    try rebuild(a, fs, &diag, &idx, .{ .scope = .system, .dirs = &.{.{ .path = "/d", .tier = .admin }} });
    try testing.expectEqual(hash.bodyHash("orig\n"), idx.findUnit("foo.service").?.files[0].out_hash);
}

test "rebuild groups meta-described files under one unit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try fs.makePath("/etc/s6/foo");
    try fs.writeFileAtomic("/etc/s6/foo/type", "longrun\n", 0o644);
    try fs.writeFileAtomic("/etc/s6/foo/run", "#!/bin/sh\n", 0o755);
    var aw: std.Io.Writer.Allocating = .init(a);
    try marker.writeMeta(&aw.writer, .{
        .unit = "foo.service",
        .source = "/usr/lib/systemd/system/foo.service",
        .source_hash = 5,
        .generator = "fake-systemd 0.1.0 s6-rc/1",
        .bodies = &.{
            .{ .path = "type", .hash = hash.bodyHash("longrun\n") },
            .{ .path = "run", .hash = hash.bodyHash("#!/bin/sh\n") },
        },
    });
    try fs.writeFileAtomic("/etc/s6/foo/fake-systemd.meta", aw.written(), 0o644);

    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var idx: Index = .init("s6-rc", 1);
    try rebuild(a, fs, &diag, &idx, .{ .scope = .system, .dirs = &.{.{ .path = "/etc/s6", .tier = .admin }} });
    try testing.expectEqual(@as(usize, 1), idx.units.items.len);
    const u = idx.findUnit("foo.service").?;
    try testing.expectEqual(@as(usize, 3), u.files.len);
    try testing.expectEqualStrings("/etc/s6/foo/type", u.files[0].path);
    try testing.expectEqualStrings("/etc/s6/foo/fake-systemd.meta", u.files[2].path);
}

test "rebuild names entries after the Unit field and handles shebang files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    try fs.makePath("/d");
    const content = try marker.compose(a, "foo@bar.service", "/s/foo@.service", 7, "fake-systemd 0.1.0 runit/1", "#!/bin/sh\nexec foo\n");
    try fs.writeFileAtomic("/d/run", content, 0o755);
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var diag: Diag = .init(&w, .info);
    var idx: Index = .init("runit", 1);
    try rebuild(a, fs, &diag, &idx, .{ .scope = .system, .dirs = &.{.{ .path = "/d", .tier = .admin }} });
    const u = idx.findUnit("foo@bar.service").?;
    try testing.expectEqual(hash.bodyHash("#!/bin/sh\nexec foo\n"), u.files[0].out_hash);
}
