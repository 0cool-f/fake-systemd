// SPDX-License-Identifier: GPL-3.0-or-later
//! `preset` and `preset-all`: apply `*.preset` files (`enable`/`disable` glob lines, first match
//! wins, files in lexical order, a file name in a higher-priority directory shadows lower ones).
const std = @import("std");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const lifecycle = @import("lifecycle.zig");
const units = @import("units.zig");

const Exit = cli.output.Exit;

pub const Action = enum { enable, disable };

pub const Rule = struct {
    /// Null for `ignore`: the unit is left alone.
    action: ?Action,
    glob: []const u8,
};

const system_dirs = [_][]const u8{
    "/etc/systemd/system-preset",
    "/run/systemd/system-preset",
    "/usr/local/lib/systemd/system-preset",
    "/usr/lib/systemd/system-preset",
    "/lib/systemd/system-preset",
};

const user_dirs = [_][]const u8{
    "/etc/systemd/user-preset",
    "/run/systemd/user-preset",
    "/usr/local/lib/systemd/user-preset",
    "/usr/lib/systemd/user-preset",
};

const PresetFile = struct {
    name: []const u8,
    path: []const u8,

    fn lessThan(_: void, a: PresetFile, b: PresetFile) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

fn collectFiles(s: *Session) ![]PresetFile {
    const gpa = s.ctx.gpa;
    const dirs: []const []const u8 = if (s.ctx.scope == .system) &system_dirs else &user_dirs;
    var files: std.ArrayList(PresetFile) = .empty;
    for (dirs) |dir| {
        const entries = s.ctx.fs.iterateDir(gpa, dir) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        for (entries) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".preset")) continue;
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            var shadowed = false;
            for (files.items) |f| if (std.mem.eql(u8, f.name, entry.name)) {
                shadowed = true;
            };
            if (shadowed) continue;
            try files.append(gpa, .{ .name = entry.name, .path = try std.fs.path.join(gpa, &.{ dir, entry.name }) });
        }
    }
    std.mem.sort(PresetFile, files.items, {}, PresetFile.lessThan);
    return files.items;
}

pub fn parseRules(gpa: std.mem.Allocator, rules: *std.ArrayList(Rule), content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const verb = words.next() orelse continue;
        const action: ?Action = if (std.mem.eql(u8, verb, "enable"))
            .enable
        else if (std.mem.eql(u8, verb, "disable"))
            .disable
        else if (std.mem.eql(u8, verb, "ignore"))
            null
        else
            continue;
        while (words.next()) |glob| try rules.append(gpa, .{ .action = action, .glob = glob });
    }
}

pub fn loadRules(s: *Session) ![]const Rule {
    const gpa = s.ctx.gpa;
    var rules: std.ArrayList(Rule) = .empty;
    for (try collectFiles(s)) |f| {
        const content = s.ctx.fs.readFileAlloc(gpa, f.path, 1 << 20) catch |e| {
            s.ctx.diag.warn("cannot read preset file {s}: {t}", .{ f.path, e });
            continue;
        };
        try parseRules(gpa, &rules, content);
    }
    return rules.items;
}

/// Action of the first rule matching `name`; null when none matches or the rule is `ignore`.
pub fn lookup(rules: []const Rule, name: []const u8) ?Action {
    for (rules) |r| {
        if (unit.name.globMatch(r.glob, name)) return r.action;
    }
    return null;
}

fn applyOne(s: *Session, name: unit.name.Name, action: Action, tolerant: bool) !u8 {
    if (tolerant) {
        const plan = pipeline.prepare(s, name) catch return Exit.success;
        switch (plan.outcome) {
            .generate, .native => {},
            else => return Exit.success,
        }
    }
    var visited: lifecycle.Visited = .empty;
    return switch (action) {
        .enable => lifecycle.enableUnit(s, name, &visited, 0),
        .disable => lifecycle.disableUnit(s, name),
    };
}

pub fn preset(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    const rules = try loadRules(s);
    var agg: units.Aggregate = .{};
    for (names) |n| {
        const action = lookup(rules, n.full) orelse continue;
        agg.note(try applyOne(s, n, action, false));
    }
    return agg.code;
}

pub fn presetAll(s: *Session) !u8 {
    const gpa = s.ctx.gpa;
    const rules = try loadRules(s);
    if (rules.len == 0) return Exit.success;
    const listed = try unit.resolve.list(gpa, s.ctx.fs.*, s.resolveOptions());
    var agg: units.Aggregate = .{};
    for (listed) |l| {
        if (l.masked or l.alias_of != null) continue;
        const name = try unit.name.parse(gpa, l.name);
        if (name.isTemplate()) continue;
        const action = lookup(rules, name.full) orelse continue;
        // One failing unit must not leave the rest of the system unpreset.
        const code = applyOne(s, name, action, true) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => blk: {
                s.ctx.diag.err("{s}: preset failed: {t}", .{ name.full, e });
                break :blk Exit.failure;
            },
        };
        agg.note(code);
    }
    return agg.code;
}

const testing = std.testing;

test "rules: comments, ignore, multiple globs and first-match lookup" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rules: std.ArrayList(Rule) = .empty;
    try parseRules(arena.allocator(), &rules, "# c\n\nenable a.service b.*\nignore keep.service\ndisable *\nbogus x\n");
    try testing.expectEqual(@as(?Action, .enable), lookup(rules.items, "a.service"));
    try testing.expectEqual(@as(?Action, .enable), lookup(rules.items, "b.service"));
    try testing.expectEqual(@as(?Action, null), lookup(rules.items, "keep.service"));
    try testing.expectEqual(@as(?Action, .disable), lookup(rules.items, "other.service"));
    try testing.expectEqual(@as(?Action, null), lookup(&.{}, "x.service"));
}
