// SPDX-License-Identifier: GPL-3.0-or-later
//! Executes reconcile decisions through `Fs`, or renders them for `--dry-run` (§3.4, §8).
//! Generated files are written before the index; callers save the index last (`Env.saveIndex`).
const std = @import("std");
const Io = std.Io;
const Fs = @import("../core/Fs.zig");
const Diag = @import("../core/Diag.zig");
const types = @import("../core/types.zig");
const hash = @import("../index/hash.zig");
const marker = @import("../index/marker.zig");
const Index = @import("../index/Index.zig");
const Layout = @import("../index/layout.zig");
const plan = @import("plan.zig");
const diff = @import("diff.zig");

/// `out_hash` recorded for a file whose original content is unknown; it never equals a real hash
/// by construction of the callers, so later runs keep the user's file.
pub const unknown_hash: u64 = 0;

pub const Env = struct {
    gpa: std.mem.Allocator,
    fs: *Fs,
    diag: *Diag,
    layout: Layout,
    verb: plan.Verb,
    dry_run: bool = false,
    /// Receives the dry-run report (stdout).
    out: *Io.Writer,

    /// Saves the index unless this is a dry run.
    pub fn saveIndex(env: *Env, index: Index) !void {
        if (env.dry_run) return;
        const path = try env.layout.indexPath(env.gpa);
        defer env.gpa.free(path);
        try index.save(env.gpa, env.fs.*, path);
    }
};

/// How the marker of a generated file is recognised.
pub const Style = enum {
    /// Leading comment block in the file itself.
    comment,
    /// A `fake-systemd.meta` file in the same directory.
    meta,
    /// The file is hashed as a whole and always counts as marked (the meta file itself).
    raw,
};

pub const Generated = struct {
    /// Complete file content, including the marker block for `.comment` files.
    content: []const u8,
    mode: u16 = 0o644,
};

pub const Target = struct {
    /// Unit name used in messages.
    unit: []const u8,
    path: []const u8,
    style: Style = .comment,
    /// `out_hash` recorded in the index; null when the file has no entry.
    original: ?u64,
    already_missing: bool = false,
    /// Null when the source unit is gone.
    new: ?Generated,
};

pub const Outcome = struct {
    action: plan.Action,
    /// `out_hash` to record afterwards; null when the file leaves the index.
    out_hash: ?u64,
    /// Stat fingerprint of the file after the action (0 when absent or dry run of a write).
    stat: u64,
};

const max_size = hash.max_file_size;

fn bodyHashOf(style: Style, content: []const u8) u64 {
    if (style == .comment) {
        if (marker.parse(content)) |p| return p.bodyHash();
    }
    return hash.bodyHash(content);
}

fn readCurrent(env: *Env, t: Target) !struct { state: plan.Current, content: ?[]u8 } {
    const content = env.fs.readFileAlloc(env.gpa, t.path, max_size) catch |e| switch (e) {
        error.FileNotFound => return .{ .state = .absent, .content = null },
        else => return e,
    };
    errdefer env.gpa.free(content);
    const has_marker = switch (t.style) {
        .comment => marker.parse(content) != null,
        .raw => true,
        .meta => blk: {
            const dir = std.fs.path.dirname(t.path) orelse "/";
            const meta = try std.fs.path.join(env.gpa, &.{ dir, marker.meta_name });
            defer env.gpa.free(meta);
            break :blk env.fs.exists(meta);
        },
    };
    return .{
        .state = .{ .present = .{ .body_hash = bodyHashOf(t.style, content), .has_marker = has_marker } },
        .content = content,
    };
}

/// Decides and performs (or reports) the action for one generated file.
pub fn reconcileFile(env: *Env, t: Target) !Outcome {
    const current = try readCurrent(env, t);
    defer if (current.content) |c| env.gpa.free(c);
    const new_hash: ?u64 = if (t.new) |n| bodyHashOf(t.style, n.content) else null;

    const decision = plan.decide(.{
        .original = t.original,
        .current = current.state,
        .new = new_hash,
        .verb = env.verb,
        .already_missing = t.already_missing,
    });

    try perform(env, t, decision.action, current.content);
    if (decision.notice) |n| try emitNotice(env, t, n);

    const out_hash: ?u64 = switch (decision.action) {
        .write => new_hash.?,
        .none => t.original orelse new_hash.?,
        .keep_local_save_fsnew, .mark_missing => t.original orelse unknown_hash,
        .remove, .move_fssave, .adopt_native => null,
    };
    const stat: u64 = switch (decision.action) {
        .remove, .move_fssave, .mark_missing => 0,
        else => hash.fileFingerprint(env.fs.*, t.path),
    };
    return .{ .action = decision.action, .out_hash = out_hash, .stat = stat };
}

fn backupFor(env: *Env, t: Target, kind: Layout.BackupKind) ![]u8 {
    return env.layout.backupPath(env.gpa, t.path, kind);
}

fn perform(env: *Env, t: Target, action: plan.Action, current: ?[]const u8) !void {
    switch (action) {
        .none, .mark_missing, .adopt_native => {},
        .write => {
            const n = t.new.?;
            if (env.dry_run) return diff.unified(env.gpa, env.out, t.path, current orelse "", n.content);
            try env.fs.makePath(std.fs.path.dirname(t.path) orelse "/");
            try env.fs.writeFileAtomic(t.path, n.content, n.mode);
        },
        .keep_local_save_fsnew => {
            const n = t.new.?;
            const backup = try backupFor(env, t, .fsnew);
            defer env.gpa.free(backup);
            if (env.dry_run) return env.out.print("save {s} (new version; {s} kept)\n", .{ backup, t.path });
            try env.fs.makePath(std.fs.path.dirname(backup) orelse "/");
            try env.fs.writeFileAtomic(backup, n.content, n.mode);
        },
        .remove => {
            if (env.dry_run) {
                if (current != null) try env.out.print("remove {s}\n", .{t.path});
                return;
            }
            env.fs.deleteFile(t.path) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            };
        },
        .move_fssave => {
            const backup = try backupFor(env, t, .fssave);
            defer env.gpa.free(backup);
            if (env.dry_run) return env.out.print("move {s} -> {s}\n", .{ t.path, backup });
            // Copy then delete: the state directory may be on another filesystem.
            const mode = (try env.fs.stat(t.path)).mode;
            try env.fs.makePath(std.fs.path.dirname(backup) orelse "/");
            try env.fs.writeFileAtomic(backup, current.?, mode);
            try env.fs.deleteFile(t.path);
        },
    }
}

fn emitNotice(env: *Env, t: Target, n: plan.Notice) !void {
    switch (n) {
        .local_changes_kept => {
            const backup = try backupFor(env, t, .fsnew);
            defer env.gpa.free(backup);
            env.diag.notice("{s}: local changes kept, new version saved to {s}", .{ t.unit, backup });
        },
        .source_removed_modified_saved => {
            const backup = try backupFor(env, t, .fssave);
            defer env.gpa.free(backup);
            env.diag.notice("{s}: source unit removed, modified file saved to {s}", .{ t.unit, backup });
        },
        .file_missing => env.diag.notice("{s}: generated file {s} is missing and is not regenerated until an explicit command", .{ t.unit, t.path }),
        .marker_removed => env.diag.info("{s}: marker removed from {s}, treating it as a native service", .{ t.unit, t.path }),
    }
}

pub const GeneratedFile = struct {
    path: []const u8,
    style: Style = .comment,
    content: []const u8,
    mode: u16 = 0o644,
};

pub const UnitSpec = struct {
    name: []const u8,
    scope: types.Scope,
    tier: types.Tier,
    src_hash: u64,
    src_stat: u64,
    generator_version: []const u8,
    files: []const GeneratedFile,
    executables: []const Index.Exec = &.{},
    origin: Index.Origin = .explicit,
    deps: []const []const u8 = &.{},
};

pub const UnitOutcome = struct {
    /// State recorded for the unit; null when the entry was removed.
    state: ?Index.State,
    /// One action per processed file, in processing order.
    actions: []const plan.Action,
};

fn inferStyle(env: *Env, path: []const u8) !Style {
    const dir = std.fs.path.dirname(path) orelse "/";
    if (std.mem.eql(u8, std.fs.path.basename(path), marker.meta_name)) return .raw;
    const meta = try std.fs.path.join(env.gpa, &.{ dir, marker.meta_name });
    defer env.gpa.free(meta);
    return if (env.fs.exists(meta)) .meta else .comment;
}

/// Reconciles every generated file of a unit against the index and updates the in-memory entry.
/// Files recorded in the index but absent from `spec` are treated as having lost their source.
/// `.raw` files (meta files) are processed last so the others still see their marker.
pub fn syncUnit(env: *Env, index: *Index, arena: std.mem.Allocator, spec: UnitSpec) !UnitOutcome {
    return runUnit(env, index, arena, spec.name, spec);
}

/// Source unit removed, or `revert`: removes unmodified files, saves modified ones as `.fssave`.
pub fn dropUnit(env: *Env, index: *Index, arena: std.mem.Allocator, name: []const u8) !UnitOutcome {
    return runUnit(env, index, arena, name, null);
}

fn runUnit(env: *Env, index: *Index, arena: std.mem.Allocator, name: []const u8, spec: ?UnitSpec) !UnitOutcome {
    const existing: ?Index.Unit = if (index.findUnit(name)) |u| u.* else null;
    const already_missing = if (existing) |u| u.state == .missing else false;

    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(env.gpa);
    if (spec) |s| for (s.files) |f| {
        try targets.append(env.gpa, .{
            .unit = name,
            .path = f.path,
            .style = f.style,
            .original = if (existing) |u| if (u.findFile(f.path)) |e| e.out_hash else null else null,
            .already_missing = already_missing,
            .new = .{ .content = f.content, .mode = f.mode },
        });
    };
    if (existing) |u| for (u.files) |e| {
        const listed = if (spec) |s| for (s.files) |f| {
            if (std.mem.eql(u8, f.path, e.path)) break true;
        } else false else false;
        if (listed) continue;
        try targets.append(env.gpa, .{
            .unit = name,
            .path = e.path,
            .style = try inferStyle(env, e.path),
            .original = e.out_hash,
            .already_missing = already_missing,
            .new = null,
        });
    };

    var files: std.ArrayList(Index.FileEntry) = .empty;
    var actions: std.ArrayList(plan.Action) = .empty;
    var any_missing = false;
    var any_native = false;
    for ([_]bool{ false, true }) |raw_pass| {
        for (targets.items) |t| {
            if ((t.style == .raw) != raw_pass) continue;
            const o = try reconcileFile(env, t);
            try actions.append(arena, o.action);
            if (o.action == .mark_missing) any_missing = true;
            if (o.action == .adopt_native) any_native = true;
            if (o.out_hash) |h| try files.append(arena, .{ .path = t.path, .out_hash = h, .stat = o.stat });
        }
    }

    const state: ?Index.State = if (any_native) .native else if (any_missing) .missing else if (files.items.len > 0) .managed else null;
    if (!env.dry_run) {
        if (state) |st| {
            const base: Index.Unit = if (spec) |s| .{
                .name = name,
                .scope = s.scope,
                .tier = s.tier,
                .state = st,
                .src_hash = s.src_hash,
                .src_stat = s.src_stat,
                .files = files.items,
                .executables = s.executables,
                .origin = s.origin,
                .deps = s.deps,
                .generator_version = s.generator_version,
            } else blk: {
                var u = existing.?;
                u.state = st;
                u.files = files.items;
                break :blk u;
            };
            try index.putUnit(arena, base);
        } else {
            _ = index.removeUnit(name);
        }
    }
    return .{ .state = state, .actions = actions.items };
}

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    fs: Fs,
    diag_buf: [4096]u8 = undefined,
    diag_w: Io.Writer = undefined,
    diag: Diag = undefined,
    out: Io.Writer.Allocating,
    index: Index,

    fn init(f: *Fixture) void {
        f.arena = .init(testing.allocator);
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.fs = .initDir(testing.io, f.tmp.dir);
        f.diag_w = .fixed(&f.diag_buf);
        f.diag = .init(&f.diag_w, .info);
        f.out = .init(testing.allocator);
        f.index = .init("dinit", 1);
    }

    fn deinit(f: *Fixture) void {
        f.out.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn env(f: *Fixture, verb: plan.Verb, dry_run: bool) Env {
        return .{
            .gpa = testing.allocator,
            .fs = &f.fs,
            .diag = &f.diag,
            .layout = .{ .state_dir = Layout.system_state_dir, .backend = "dinit" },
            .verb = verb,
            .dry_run = dry_run,
            .out = &f.out.writer,
        };
    }

    fn content(f: *Fixture, body: []const u8) ![]const u8 {
        return marker.compose(f.arena.allocator(), "foo.service", "/usr/lib/systemd/system/foo.service", 1, "fake-systemd 0.1.0 dinit/1", body);
    }

    fn spec(f: *Fixture, body: []const u8) !UnitSpec {
        const a = f.arena.allocator();
        const files = try a.alloc(GeneratedFile, 1);
        files[0] = .{ .path = "/etc/dinit.d/foo", .content = try f.content(body) };
        return .{
            .name = "foo.service",
            .scope = .system,
            .tier = .admin,
            .src_hash = 1,
            .src_stat = 2,
            .generator_version = "0.1.0",
            .files = files,
        };
    }

    fn read(f: *Fixture, path: []const u8) ![]u8 {
        return f.fs.readFileAlloc(f.arena.allocator(), path, 1 << 20);
    }
};

const backup_new = "/var/lib/fake-systemd/backup/dinit/etc/dinit.d/foo.fsnew";
const backup_save = "/var/lib/fake-systemd/backup/dinit/etc/dinit.d/foo.fssave";

test "first write creates the file and the index entry" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.explicit, false);
    const o = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try testing.expectEqual(Index.State.managed, o.state.?);
    try testing.expectEqual(plan.Action.write, o.actions[0]);
    try testing.expectEqualStrings(try f.content("v1\n"), try f.read("/etc/dinit.d/foo"));
    const u = f.index.findUnit("foo.service").?;
    try testing.expectEqual(hash.bodyHash("v1\n"), u.files[0].out_hash);
    try testing.expect(u.files[0].stat != 0);
    try env.saveIndex(f.index);
    try testing.expect(f.fs.exists("/var/lib/fake-systemd/dinit/index"));
}

test "regeneration overwrites an unmodified file and is a no-op when unchanged" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.explicit, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    const same = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try testing.expectEqual(plan.Action.none, same.actions[0]);
    const upd = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v2\n"));
    try testing.expectEqual(plan.Action.write, upd.actions[0]);
    try testing.expectEqualStrings(try f.content("v2\n"), try f.read("/etc/dinit.d/foo"));
    try testing.expectEqual(hash.bodyHash("v2\n"), f.index.findUnit("foo.service").?.files[0].out_hash);
}

test "local edit plus new generation keeps the file and saves .fsnew with a notice" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.explicit, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    const edited = try std.mem.concat(f.arena.allocator(), u8, &.{ try f.content("v1\n"), "mine\n" });
    try f.fs.makePath("/etc/dinit.d");
    try f.fs.writeFileAtomic("/etc/dinit.d/foo", edited, 0o644);
    const o = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v2\n"));
    try testing.expectEqual(plan.Action.keep_local_save_fsnew, o.actions[0]);
    try testing.expectEqualStrings(edited, try f.read("/etc/dinit.d/foo"));
    try testing.expectEqualStrings(try f.content("v2\n"), try f.read(backup_new));
    try testing.expectEqualStrings(
        "fake-systemd: foo.service: local changes kept, new version saved to " ++ backup_new ++ "\n",
        f.diag_w.buffered(),
    );
    try testing.expectEqual(hash.bodyHash("v1\n"), f.index.findUnit("foo.service").?.files[0].out_hash);
}

test "local edit with unchanged generation is left alone silently" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.explicit, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    const edited = try std.mem.concat(f.arena.allocator(), u8, &.{ try f.content("v1\n"), "mine\n" });
    try f.fs.makePath("/etc/dinit.d");
    try f.fs.writeFileAtomic("/etc/dinit.d/foo", edited, 0o644);
    const o = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try testing.expectEqual(plan.Action.none, o.actions[0]);
    try testing.expectEqualStrings(edited, try f.read("/etc/dinit.d/foo"));
    try testing.expectEqualStrings("", f.diag_w.buffered());
}

test "source removal deletes an unmodified file and drops the entry" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.daemon_reload, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    const o = try dropUnit(&env, &f.index, f.arena.allocator(), "foo.service");
    try testing.expect(o.state == null);
    try testing.expect(!f.fs.exists("/etc/dinit.d/foo"));
    try testing.expect(f.index.findUnit("foo.service") == null);
}

test "source removal moves a modified file to .fssave" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.daemon_reload, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    const edited = try std.mem.concat(f.arena.allocator(), u8, &.{ try f.content("v1\n"), "mine\n" });
    try f.fs.makePath("/etc/dinit.d");
    try f.fs.writeFileAtomic("/etc/dinit.d/foo", edited, 0o640);
    const o = try dropUnit(&env, &f.index, f.arena.allocator(), "foo.service");
    try testing.expect(o.state == null);
    try testing.expect(!f.fs.exists("/etc/dinit.d/foo"));
    try testing.expectEqualStrings(edited, try f.read(backup_save));
    try testing.expectEqual(@as(u16, 0o640), (try f.fs.stat(backup_save)).mode);
    try testing.expect(std.mem.find(u8, f.diag_w.buffered(), "foo.service: source unit removed, modified file saved to " ++ backup_save) != null);
}

test "a deleted file is marked missing on reload and regenerated by explicit verbs" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.explicit, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try f.fs.deleteFile("/etc/dinit.d/foo");

    var reload = f.env(.daemon_reload, false);
    const o1 = try syncUnit(&reload, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try testing.expectEqual(Index.State.missing, o1.state.?);
    try testing.expect(!f.fs.exists("/etc/dinit.d/foo"));
    try testing.expectEqual(hash.bodyHash("v1\n"), f.index.findUnit("foo.service").?.files[0].out_hash);
    const first_notice = try testing.allocator.dupe(u8, f.diag_w.buffered());
    defer testing.allocator.free(first_notice);
    try testing.expect(std.mem.find(u8, first_notice, "is missing") != null);

    const o2 = try syncUnit(&reload, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try testing.expectEqual(Index.State.missing, o2.state.?);
    try testing.expectEqualStrings(first_notice, f.diag_w.buffered());

    const o3 = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try testing.expectEqual(Index.State.managed, o3.state.?);
    try testing.expect(f.fs.exists("/etc/dinit.d/foo"));
}

test "removing the marker turns the unit native without any backup" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.daemon_reload, false);
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    try f.fs.makePath("/etc/dinit.d");
    try f.fs.writeFileAtomic("/etc/dinit.d/foo", "type = process\n", 0o644);
    const o = try syncUnit(&env, &f.index, f.arena.allocator(), try f.spec("v2\n"));
    try testing.expectEqual(Index.State.native, o.state.?);
    try testing.expectEqual(plan.Action.adopt_native, o.actions[0]);
    try testing.expectEqualStrings("type = process\n", try f.read("/etc/dinit.d/foo"));
    try testing.expect(!f.fs.exists(backup_save));
    try testing.expect(!f.fs.exists(backup_new));
    const u = f.index.findUnit("foo.service").?;
    try testing.expectEqual(Index.State.native, u.state);
    try testing.expectEqual(@as(usize, 0), u.files.len);
    try testing.expect(std.mem.find(u8, f.diag_w.buffered(), "info: foo.service: marker removed") != null);

    const gone = try dropUnit(&env, &f.index, f.arena.allocator(), "foo.service");
    try testing.expect(gone.state == null);
}

test "dry run reports a diff for a new file and writes nothing" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.explicit, true);
    const spec = try f.spec("v1\n");
    _ = try syncUnit(&env, &f.index, f.arena.allocator(), spec);
    try testing.expect(!f.fs.exists("/etc"));
    try testing.expect(!f.fs.exists("/var"));
    try testing.expect(f.index.findUnit("foo.service") == null);
    try env.saveIndex(f.index);
    try testing.expect(!f.fs.exists("/var"));
    const out = f.out.written();
    try testing.expect(std.mem.startsWith(u8, out, "--- a/etc/dinit.d/foo\n+++ b/etc/dinit.d/foo\n@@ -0,0 +1,7 @@\n+# Generated automatically"));
}

test "dry run reports modification diffs, removals, backups and writes no files" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var real = f.env(.explicit, false);
    _ = try syncUnit(&real, &f.index, f.arena.allocator(), try f.spec("v1\n"));
    const before = try f.read("/etc/dinit.d/foo");

    var dry = f.env(.explicit, true);
    _ = try syncUnit(&dry, &f.index, f.arena.allocator(), try f.spec("v2\n"));
    try testing.expect(std.mem.find(u8, f.out.written(), "-v1\n+v2\n") != null);
    try testing.expectEqualStrings(before, try f.read("/etc/dinit.d/foo"));
    try testing.expectEqual(hash.bodyHash("v1\n"), f.index.findUnit("foo.service").?.files[0].out_hash);

    f.out.writer.end = 0;
    var dry_reload = f.env(.daemon_reload, true);
    _ = try dropUnit(&dry_reload, &f.index, f.arena.allocator(), "foo.service");
    try testing.expectEqualStrings("remove /etc/dinit.d/foo\n", f.out.written());
    try testing.expect(f.fs.exists("/etc/dinit.d/foo"));
    try testing.expect(f.index.findUnit("foo.service") != null);

    const edited = try std.mem.concat(f.arena.allocator(), u8, &.{ before, "mine\n" });
    try f.fs.makePath("/etc/dinit.d");
    try f.fs.writeFileAtomic("/etc/dinit.d/foo", edited, 0o644);
    f.out.writer.end = 0;
    _ = try dropUnit(&dry_reload, &f.index, f.arena.allocator(), "foo.service");
    try testing.expectEqualStrings("move /etc/dinit.d/foo -> " ++ backup_save ++ "\n", f.out.written());
    try testing.expect(!f.fs.exists(backup_save));

    f.out.writer.end = 0;
    _ = try syncUnit(&dry, &f.index, f.arena.allocator(), try f.spec("v3\n"));
    try testing.expectEqualStrings("save " ++ backup_new ++ " (new version; /etc/dinit.d/foo kept)\n", f.out.written());
    try testing.expect(!f.fs.exists(backup_new));
}

test "meta-style files keep their marker through a dropped sibling" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env = f.env(.daemon_reload, false);
    const a = f.arena.allocator();
    const files = try a.dupe(GeneratedFile, &.{
        .{ .path = "/etc/s6/foo/fake-systemd.meta", .style = .raw, .content = "meta\n" },
        .{ .path = "/etc/s6/foo/run", .style = .meta, .content = "run\n" },
    });
    const spec: UnitSpec = .{ .name = "foo.service", .scope = .system, .tier = .admin, .src_hash = 1, .src_stat = 2, .generator_version = "0.1.0", .files = files };
    var explicit = f.env(.explicit, false);
    _ = try syncUnit(&explicit, &f.index, a, spec);
    try testing.expectEqualStrings("run\n", try f.read("/etc/s6/foo/run"));

    const o = try dropUnit(&env, &f.index, a, "foo.service");
    try testing.expect(o.state == null);
    try testing.expect(!f.fs.exists("/etc/s6/foo/run"));
    try testing.expect(!f.fs.exists("/etc/s6/foo/fake-systemd.meta"));
}
