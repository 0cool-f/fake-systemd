// SPDX-License-Identifier: GPL-3.0-or-later
//! Unit arguments: name validation and glob expansion (§3.3), and exit-code aggregation.
const std = @import("std");
const unit = @import("../unit/root.zig");
const Session = @import("session.zig");

const Name = unit.name.Name;

/// Keeps the first non-zero exit code, as systemctl does for several units.
pub const Aggregate = struct {
    code: u8 = 0,

    pub fn note(a: *Aggregate, code: u8) void {
        if (a.code == 0) a.code = code;
    }
};

/// Parses the unit arguments of the request. Returns null after reporting an invalid name;
/// no filesystem access happens before every name is valid.
pub fn parseArgs(s: *Session) !?[]const Name {
    const gpa = s.ctx.gpa;
    var names: std.ArrayList(Name) = .empty;
    var globs: std.ArrayList([]const u8) = .empty;
    var invalid = false;
    for (s.req.units) |arg| {
        if (unit.name.hasGlob(arg)) {
            try globs.append(gpa, arg);
            continue;
        }
        const parsed = unit.name.parse(gpa, arg) catch |e| switch (e) {
            error.InvalidName => {
                s.ctx.diag.err("invalid unit name '{s}'", .{arg});
                invalid = true;
                continue;
            },
            else => return e,
        };
        try appendUnique(gpa, &names, parsed);
    }
    if (invalid) return null;
    for (globs.items) |pattern| try expandGlob(s, &names, pattern);
    return names.items;
}

fn appendUnique(gpa: std.mem.Allocator, names: *std.ArrayList(Name), name: Name) !void {
    for (names.items) |n| if (std.mem.eql(u8, n.full, name.full)) return;
    try names.append(gpa, name);
}

fn expandGlob(s: *Session, names: *std.ArrayList(Name), pattern: []const u8) !void {
    const gpa = s.ctx.gpa;
    const listed = try unit.resolve.list(gpa, s.ctx.fs.*, s.resolveOptions());
    var matched = false;
    for (listed) |l| {
        const parsed = try unit.name.parse(gpa, l.name);
        if (parsed.isTemplate()) continue;
        const short = if (parsed.kind == .service) parsed.base() else parsed.full;
        if (!unit.name.globMatch(pattern, parsed.full) and !unit.name.globMatch(pattern, short)) continue;
        matched = true;
        try appendUnique(gpa, names, parsed);
    }
    if (!matched) s.ctx.diag.info("pattern '{s}' matched no unit", .{pattern});
}

/// Reports a missing unit argument; returns the exit code to use.
pub fn tooFew(s: *Session) u8 {
    s.ctx.diag.err("too few arguments", .{});
    return 1;
}

test "aggregate keeps the first failure" {
    var a: Aggregate = .{};
    a.note(0);
    a.note(5);
    a.note(1);
    try std.testing.expectEqual(@as(u8, 5), a.code);
}

/// Names the requested units whose files are over the size limit, after a verb failed with
/// `UnitFileTooLarge`; false when none of them is.
pub fn reportOversized(s: *Session) bool {
    var found = false;
    for (s.req.units) |arg| {
        const name = unit.name.parse(s.ctx.gpa, arg) catch continue;
        const resolved = unit.resolve.resolve(s.ctx.gpa, s.ctx.fs.*, s.resolveOptions(), name) catch continue;
        for (resolved.files) |ref| {
            const st = s.ctx.fs.stat(ref.read_path) catch continue;
            if (st.size <= unit.resolve.max_unit_file_size) continue;
            s.ctx.diag.err("{s}: {s} is larger than {d} bytes, the limit for unit files", .{ name.full, ref.path, unit.resolve.max_unit_file_size });
            found = true;
        }
    }
    return found;
}
