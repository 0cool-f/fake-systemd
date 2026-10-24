//! Unified diff (`--- a/<path>` / `+++ b/<path>`, 3 lines of context) for `--dry-run` output.
const std = @import("std");
const Io = std.Io;

pub const context_lines = 3;
/// Largest middle section (old lines times new lines) compared line by line; beyond it the
/// section is reported as a full replacement.
const max_cells: u64 = 16 << 20;

const Op = enum(u8) { equal, delete, insert };

/// Lines keep their trailing newline, so a missing final newline makes a line differ.
fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var rest = text;
    while (rest.len > 0) {
        const end = if (std.mem.findScalar(u8, rest, '\n')) |i| i + 1 else rest.len;
        try list.append(gpa, rest[0..end]);
        rest = rest[end..];
    }
    return list.toOwnedSlice(gpa);
}

fn buildOps(gpa: std.mem.Allocator, old: []const []const u8, new: []const []const u8) ![]Op {
    var prefix: usize = 0;
    while (prefix < old.len and prefix < new.len and std.mem.eql(u8, old[prefix], new[prefix])) prefix += 1;
    var suffix: usize = 0;
    while (suffix < old.len - prefix and suffix < new.len - prefix and
        std.mem.eql(u8, old[old.len - 1 - suffix], new[new.len - 1 - suffix])) suffix += 1;
    const a = old[prefix .. old.len - suffix];
    const b = new[prefix .. new.len - suffix];

    var ops: std.ArrayList(Op) = .empty;
    errdefer ops.deinit(gpa);
    try ops.appendNTimes(gpa, .equal, prefix);
    try middleOps(gpa, &ops, a, b);
    try ops.appendNTimes(gpa, .equal, suffix);
    return ops.toOwnedSlice(gpa);
}

fn middleOps(gpa: std.mem.Allocator, ops: *std.ArrayList(Op), a: []const []const u8, b: []const []const u8) !void {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0 or @as(u64, n) * m > max_cells) {
        try ops.appendNTimes(gpa, .delete, n);
        try ops.appendNTimes(gpa, .insert, m);
        return;
    }
    // lcs[i][j]: length of the longest common subsequence of a[i..] and b[j..].
    const w = m + 1;
    const lcs = try gpa.alloc(u32, (n + 1) * w);
    defer gpa.free(lcs);
    @memset(lcs[n * w ..], 0);
    var i = n;
    while (i > 0) {
        i -= 1;
        lcs[i * w + m] = 0;
        var j = m;
        while (j > 0) {
            j -= 1;
            lcs[i * w + j] = if (std.mem.eql(u8, a[i], b[j]))
                lcs[(i + 1) * w + j + 1] + 1
            else
                @max(lcs[(i + 1) * w + j], lcs[i * w + j + 1]);
        }
    }
    var x: usize = 0;
    var y: usize = 0;
    while (x < n and y < m) {
        if (std.mem.eql(u8, a[x], b[y])) {
            try ops.append(gpa, .equal);
            x += 1;
            y += 1;
        } else if (lcs[(x + 1) * w + y] >= lcs[x * w + y + 1]) {
            try ops.append(gpa, .delete);
            x += 1;
        } else {
            try ops.append(gpa, .insert);
            y += 1;
        }
    }
    try ops.appendNTimes(gpa, .delete, n - x);
    try ops.appendNTimes(gpa, .insert, m - y);
}

fn writeLine(w: *Io.Writer, sign: u8, line: []const u8) Io.Writer.Error!void {
    try w.writeByte(sign);
    try w.writeAll(line);
    if (line[line.len - 1] != '\n') try w.writeAll("\n\\ No newline at end of file\n");
}

fn writeRange(w: *Io.Writer, start: usize, len: usize) Io.Writer.Error!void {
    // An empty range is anchored at the line before it.
    const first = if (len == 0) start else start + 1;
    try w.print("{d}", .{first});
    if (len != 1) try w.print(",{d}", .{len});
}

/// Leading slashes of `path` are dropped in the headers. Writes nothing when `old` and `new` are equal.
pub fn unified(gpa: std.mem.Allocator, w: *Io.Writer, path: []const u8, old: []const u8, new: []const u8) !void {
    if (std.mem.eql(u8, old, new)) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old_lines = try splitLines(arena, old);
    const new_lines = try splitLines(arena, new);
    const ops = try buildOps(arena, old_lines, new_lines);

    const shown = std.mem.trimStart(u8, path, "/");
    try w.print("--- a/{s}\n+++ b/{s}\n", .{ shown, shown });

    // old_pos[i] / new_pos[i]: lines consumed from each side before op i.
    const old_pos = try arena.alloc(usize, ops.len + 1);
    const new_pos = try arena.alloc(usize, ops.len + 1);
    var o: usize = 0;
    var n: usize = 0;
    for (ops, 0..) |op, i| {
        old_pos[i] = o;
        new_pos[i] = n;
        if (op != .insert) o += 1;
        if (op != .delete) n += 1;
    }
    old_pos[ops.len] = o;
    new_pos[ops.len] = n;

    var i: usize = 0;
    while (i < ops.len) {
        while (i < ops.len and ops[i] == .equal) i += 1;
        if (i == ops.len) break;
        const start = i -| context_lines;
        var last = i;
        var end = i;
        var k = i;
        while (k < ops.len) : (k += 1) {
            if (ops[k] != .equal) {
                last = k;
                end = @min(ops.len, k + 1 + context_lines);
            } else if (k - last > 2 * context_lines) {
                break;
            }
        }
        try w.writeAll("@@ -");
        try writeRange(w, old_pos[start], old_pos[end] - old_pos[start]);
        try w.writeAll(" +");
        try writeRange(w, new_pos[start], new_pos[end] - new_pos[start]);
        try w.writeAll(" @@\n");
        for (start..end) |idx| {
            switch (ops[idx]) {
                .equal => try writeLine(w, ' ', old_lines[old_pos[idx]]),
                .delete => try writeLine(w, '-', old_lines[old_pos[idx]]),
                .insert => try writeLine(w, '+', new_lines[new_pos[idx]]),
            }
        }
        i = end;
    }
}

const testing = std.testing;

fn expectDiff(old: []const u8, new: []const u8, expected: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try unified(testing.allocator, &aw.writer, "etc/dinit.d/foo", old, new);
    try testing.expectEqualStrings(expected, aw.written());
}

test "new file against empty" {
    try expectDiff("", "a\nb\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -0,0 +1,2 @@
        \\+a
        \\+b
        \\
    );
}

test "deletion against empty" {
    try expectDiff("a\nb\n", "",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
        \\
    );
}

test "modification with context" {
    try expectDiff("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\n2\n3\n4\nFIVE\n6\n7\n8\n9\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -2,7 +2,7 @@
        \\ 2
        \\ 3
        \\ 4
        \\-5
        \\+FIVE
        \\ 6
        \\ 7
        \\ 8
        \\
    );
}

test "single-line files omit the length" {
    try expectDiff("a\n", "b\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -1 +1 @@
        \\-a
        \\+b
        \\
    );
}

test "distant changes produce separate hunks, close ones merge" {
    const base = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n";
    try expectDiff(base, "X\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\nY\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -1,4 +1,4 @@
        \\-1
        \\+X
        \\ 2
        \\ 3
        \\ 4
        \\@@ -12,4 +12,4 @@
        \\ 12
        \\ 13
        \\ 14
        \\-15
        \\+Y
        \\
    );
    try expectDiff("1\n2\n3\n4\n5\n6\n7\n8\n", "X\n2\n3\n4\n5\n6\n7\nY\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -1,8 +1,8 @@
        \\-1
        \\+X
        \\ 2
        \\ 3
        \\ 4
        \\ 5
        \\ 6
        \\ 7
        \\-8
        \\+Y
        \\
    );
}

test "insertion and deletion in the middle" {
    try expectDiff("a\nb\nc\n", "a\nc\nd\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -1,3 +1,3 @@
        \\ a
        \\-b
        \\ c
        \\+d
        \\
    );
}

test "missing final newline is marked" {
    try expectDiff("a\nb", "a\nb\n",
        \\--- a/etc/dinit.d/foo
        \\+++ b/etc/dinit.d/foo
        \\@@ -1,2 +1,2 @@
        \\ a
        \\-b
        \\\ No newline at end of file
        \\+b
        \\
    );
}

test "equal inputs produce no output" {
    try expectDiff("same\n", "same\n", "");
    try expectDiff("", "", "");
}
