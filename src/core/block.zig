// SPDX-License-Identifier: GPL-3.0-or-later
//! Strict parser of a managed block: a run of lines from a BEGIN marker line to an END marker
//! line inside a file that has other content. A block is only valid when the file holds exactly
//! one BEGIN followed by exactly one END; any other shape is reported with its line number and
//! the caller leaves the file untouched.
const std = @import("std");
const Diag = @import("Diag.zig");

pub const Bounds = struct {
    /// Offset of the BEGIN line.
    start: usize,
    /// Offset after the END line and its newline.
    end: usize,
};

pub const Reason = enum {
    nested_begin,
    duplicate_begin,
    end_without_begin,
    duplicate_end,
    missing_end,

    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .nested_begin => "BEGIN marker inside a block",
            .duplicate_begin => "second BEGIN marker",
            .end_without_begin => "END marker without a BEGIN marker",
            .duplicate_end => "second END marker",
            .missing_end => "BEGIN marker without an END marker",
        };
    }
};

pub const Fault = struct {
    /// 1-based line of the marker at fault.
    line: usize,
    reason: Reason,
};

pub const Found = union(enum) {
    none,
    block: Bounds,
    malformed: Fault,
};

pub const Error = error{MalformedBlock};

fn isMarker(line: []const u8, marker: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \t\r"), marker);
}

/// Where the block of `content` lies, or why the file does not hold exactly one block.
pub fn locate(content: []const u8, begin: []const u8, end: []const u8) Found {
    var at: usize = 0;
    var line_no: usize = 0;
    var start: ?usize = null;
    var begin_line: usize = 0;
    var bounds: ?Bounds = null;
    while (at < content.len) {
        line_no += 1;
        const eol = std.mem.findScalarPos(u8, content, at, '\n') orelse content.len;
        const line = content[at..eol];
        const next = @min(eol + 1, content.len);
        if (isMarker(line, begin)) {
            if (start != null) return .{ .malformed = .{ .line = line_no, .reason = .nested_begin } };
            if (bounds != null) return .{ .malformed = .{ .line = line_no, .reason = .duplicate_begin } };
            start = at;
            begin_line = line_no;
        } else if (isMarker(line, end)) {
            if (start) |s| {
                bounds = .{ .start = s, .end = next };
                start = null;
            } else {
                const reason: Reason = if (bounds != null) .duplicate_end else .end_without_begin;
                return .{ .malformed = .{ .line = line_no, .reason = reason } };
            }
        }
        at = next;
    }
    if (start != null) return .{ .malformed = .{ .line = begin_line, .reason = .missing_end } };
    if (bounds) |b| return .{ .block = b };
    return .none;
}

/// The bounds of the block, null when there is none; `error.MalformedBlock` with `fault` set otherwise.
pub fn find(content: []const u8, begin: []const u8, end: []const u8, fault: *Fault) Error!?Bounds {
    switch (locate(content, begin, end)) {
        .none => return null,
        .block => |b| return b,
        .malformed => |f| {
            fault.* = f;
            return error.MalformedBlock;
        },
    }
}

/// Reports a malformed block of `path` as an error that names the file and the line.
pub fn report(diag: *Diag, path: []const u8, fault: Fault) void {
    diag.err("{s}:{d}: {s}; the file is left untouched", .{ path, fault.line, fault.reason.text() });
}

/// `content` with the block replaced by `block`, or removed when `block` is null; a file without
/// a block gets it appended when `block` is given. Every byte outside the block is kept.
pub fn replace(gpa: std.mem.Allocator, content: []const u8, begin: []const u8, end: []const u8, block: ?[]const u8, fault: *Fault) (Error || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (try find(content, begin, end, fault)) |b| {
        try out.appendSlice(gpa, content[0..b.start]);
        if (block) |text| try out.appendSlice(gpa, text);
        try out.appendSlice(gpa, content[b.end..]);
    } else {
        try out.appendSlice(gpa, content);
        if (block) |text| {
            if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
            try out.appendSlice(gpa, text);
        }
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;
const tb = "# BEGIN x";
const te = "# END x";

fn expectFault(content: []const u8, line: usize, reason: Reason) !void {
    switch (locate(content, tb, te)) {
        .malformed => |f| {
            try testing.expectEqual(line, f.line);
            try testing.expectEqual(reason, f.reason);
        },
        else => return error.TestExpectedMalformed,
    }
}

test "exactly one block is found" {
    try testing.expect(locate("", tb, te) == .none);
    try testing.expect(locate("a\nb\n", tb, te) == .none);
    const found = locate("a\n# BEGIN x\nm\n# END x\nz", tb, te).block;
    try testing.expectEqual(@as(usize, 2), found.start);
    try testing.expectEqual(@as(usize, 22), found.end);
    const no_newline = locate("# BEGIN x\n# END x", tb, te).block;
    try testing.expectEqual(@as(usize, 17), no_newline.end);
}

test "a block with a missing, duplicated or nested marker is malformed" {
    try expectFault("a\n# BEGIN x\nuser\n", 2, .missing_end);
    try expectFault("# END x\n", 1, .end_without_begin);
    try expectFault("# END x\n# BEGIN x\n", 1, .end_without_begin);
    try expectFault("# BEGIN x\n# BEGIN x\n# END x\n", 2, .nested_begin);
    try expectFault("# BEGIN x\n# END x\nu\n# BEGIN x\n# END x\n", 4, .duplicate_begin);
    try expectFault("# BEGIN x\n# END x\n# END x\n", 3, .duplicate_end);
}

test "replace keeps every byte outside the block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var fault: Fault = undefined;
    const out = try replace(arena.allocator(), "a \r\n\n# BEGIN x\nold\n# END x\n\n\nz", tb, te, "# BEGIN x\nnew\n# END x\n", &fault);
    try testing.expectEqualStrings("a \r\n\n# BEGIN x\nnew\n# END x\n\n\nz", out);
    try testing.expectError(error.MalformedBlock, replace(arena.allocator(), "u1\n# BEGIN x\nu2\n", tb, te, null, &fault));
    try testing.expectEqual(Reason.missing_end, fault.reason);
}
