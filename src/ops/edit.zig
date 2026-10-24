//! `edit`: opens a drop-in `override.conf` in the editor, then syncs the unit (§3.1).
const std = @import("std");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const lifecycle = @import("lifecycle.zig");
const units = @import("units.zig");

const Exit = cli.output.Exit;

const initial_content = "[Service]\n";

fn editorWords(s: *Session) ![]const []const u8 {
    const raw = for ([_][]const u8{ "SYSTEMD_EDITOR", "EDITOR", "VISUAL" }) |var_name| {
        const v = s.ctx.getEnv(var_name) orelse continue;
        if (std.mem.trim(u8, v, " \t").len > 0) break v;
    } else "vi";
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |w| try words.append(s.ctx.gpa, w);
    return words.items;
}

fn syncAfterEdit(s: *Session, name: unit.name.Name) !void {
    const idx = try s.index(.write);
    if (idx.findUnit(name.full) == null) return;
    const plan = try pipeline.prepare(s, name);
    if (plan.outcome != .generate) return;
    _ = try pipeline.commit(s, &plan, .daemon_reload);
}

/// Removes the file created for the edit, and its directory when nothing else is in it.
fn cleanupCreated(s: *Session, dir: []const u8, path: []const u8) !void {
    try s.ctx.fs.deleteFile(path);
    const rest = try s.ctx.fs.iterateDir(s.ctx.gpa, dir);
    if (rest.len == 0) try s.ctx.fs.deleteTree(dir);
}

fn editOne(s: *Session, name: unit.name.Name) !u8 {
    const gpa = s.ctx.gpa;
    const resolved = try unit.resolve.resolve(gpa, s.ctx.fs.*, s.resolveOptions(), name);
    if (resolved.state == .not_found) {
        try cli.output.writeUnitDoesNotExist(s.err(), "edit", name.full);
        return Exit.failure;
    }
    const dir = try std.fmt.allocPrint(gpa, "{s}/{s}.d", .{ try lifecycle.adminDir(s, false), name.full });
    const path = try std.fs.path.join(gpa, &.{ dir, "override.conf" });
    const before: ?[]u8 = s.ctx.fs.readFileAlloc(gpa, path, unit.resolve.max_unit_file_size) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    if (!s.ctx.dry_run and before == null) {
        try s.ctx.fs.makePath(dir);
        try s.ctx.fs.writeFileAtomic(path, initial_content, 0o644);
    }

    const words = try editorWords(s);
    const argv = try std.mem.concat(gpa, []const u8, &.{ words, &.{path} });
    const res = s.runner().run(gpa, argv, .inherit) catch |e| {
        s.ctx.diag.err("cannot run editor '{s}': {t}", .{ words[0], e });
        if (before == null and !s.ctx.dry_run) try cleanupCreated(s, dir, path);
        return Exit.failure;
    };
    if (s.ctx.dry_run) return Exit.success;
    if (res.code != 0) {
        s.ctx.diag.err("editor exited with status {d}", .{res.code});
        return Exit.failure;
    }
    const after = try s.ctx.fs.readFileAlloc(gpa, path, unit.resolve.max_unit_file_size);
    const unchanged = if (before) |b| std.mem.eql(u8, b, after) else std.mem.eql(u8, std.mem.trim(u8, after, " \t\r\n"), std.mem.trim(u8, initial_content, "\n"));
    if (unchanged) {
        if (before == null) try cleanupCreated(s, dir, path);
        s.ctx.diag.notice("{s}: no changes made", .{name.full});
        return Exit.success;
    }
    try syncAfterEdit(s, name);
    return Exit.success;
}

pub fn run(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var agg: units.Aggregate = .{};
    for (names) |n| agg.note(try editOne(s, n));
    return agg.code;
}
