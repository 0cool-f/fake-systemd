//! `EnvironmentFile=` parser with systemd's `KEY=VALUE` syntax (not shell syntax).
//! Comment lines start with `#` or `;`. Values may be quoted with `'` or `"` and span lines;
//! a backslash before a newline continues the line. Unquoted and single-quoted text drops the
//! backslash of an escape; double quotes unescape only `"`, `\`, `$` and backtick. Unquoted
//! whitespace around a value is trimmed. Keys that are not valid variable names (including
//! `export FOO`) are ignored.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct { name: []const u8, value: []const u8 };

pub const Error = error{UnterminatedQuote} || Allocator.Error;

const State = enum {
    pre_key,
    key,
    pre_value,
    value,
    value_escape,
    single,
    single_escape,
    double,
    double_escape,
    comment,
    comment_escape,
};

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Parses `content` in file order. Later assignments of a name are kept as separate entries.
/// Results are allocated with `gpa`, which is expected to be an arena.
pub fn parse(gpa: Allocator, content: []const u8) Error![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var key: std.ArrayList(u8) = .empty;
    var value: std.ArrayList(u8) = .empty;
    // Bytes of `value` that are not trailing unquoted whitespace.
    var keep: usize = 0;
    var state: State = .pre_key;

    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == '\r' and i + 1 < content.len and content[i + 1] == '\n') continue;
        const newline = c == '\n' or c == '\r';
        switch (state) {
            .pre_key => if (newline or isBlank(c)) {} else if (c == '#' or c == ';') {
                state = .comment;
            } else {
                key.clearRetainingCapacity();
                try key.append(gpa, c);
                state = .key;
            },
            .comment => if (newline) {
                state = .pre_key;
            } else if (c == '\\') {
                state = .comment_escape;
            },
            .comment_escape => state = .comment,
            .key => if (newline) {
                state = .pre_key;
            } else if (c == '=') {
                value.clearRetainingCapacity();
                keep = 0;
                state = .pre_value;
            } else {
                try key.append(gpa, c);
            },
            .pre_value => if (isBlank(c)) {} else if (newline) {
                try finish(gpa, &entries, key.items, &value, keep);
                state = .pre_key;
            } else {
                state = .value;
                i -= 1;
            },
            .value => {
                if (newline) {
                    try finish(gpa, &entries, key.items, &value, keep);
                    state = .pre_key;
                } else if (c == '\\') {
                    state = .value_escape;
                } else if (c == '\'') {
                    state = .single;
                } else if (c == '"') {
                    state = .double;
                } else {
                    try value.append(gpa, c);
                    if (!isBlank(c)) keep = value.items.len;
                }
            },
            .value_escape => {
                state = .value;
                if (!newline) {
                    try value.append(gpa, c);
                    keep = value.items.len;
                }
            },
            .single => {
                if (c == '\'') {
                    state = .value;
                } else if (c == '\\') {
                    state = .single_escape;
                } else {
                    try value.append(gpa, c);
                    keep = value.items.len;
                }
            },
            .single_escape => {
                state = .single;
                if (!newline) {
                    try value.append(gpa, c);
                    keep = value.items.len;
                }
            },
            .double => {
                if (c == '"') {
                    state = .value;
                } else if (c == '\\') {
                    state = .double_escape;
                } else {
                    try value.append(gpa, c);
                    keep = value.items.len;
                }
            },
            .double_escape => {
                state = .double;
                if (!newline) {
                    if (std.mem.findScalar(u8, "\"\\`$", c) == null) try value.append(gpa, '\\');
                    try value.append(gpa, c);
                    keep = value.items.len;
                }
            },
        }
    }
    switch (state) {
        .pre_value, .value, .value_escape => try finish(gpa, &entries, key.items, &value, keep),
        .single, .single_escape, .double, .double_escape => return error.UnterminatedQuote,
        else => {},
    }
    return entries.toOwnedSlice(gpa);
}

fn finish(gpa: Allocator, entries: *std.ArrayList(Entry), raw_key: []const u8, value: *std.ArrayList(u8), keep: usize) Allocator.Error!void {
    const name = std.mem.trimEnd(u8, raw_key, " \t");
    if (!isValidName(name) or std.mem.findScalar(u8, value.items[0..keep], 0) != null) return;
    try entries.append(gpa, .{
        .name = try gpa.dupe(u8, name),
        .value = try gpa.dupe(u8, value.items[0..keep]),
    });
}

fn expectEntries(content: []const u8, expected: []const [2][]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try parse(arena.allocator(), content);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, entry| {
        try std.testing.expectEqualStrings(want[0], entry.name);
        try std.testing.expectEqualStrings(want[1], entry.value);
    }
}

test "plain assignments and comments" {
    try expectEntries(
        \\# comment
        \\; another
        \\A=1
        \\  B = two words  
        \\C=
        \\
        \\D=a#b
        \\
    , &.{ .{ "A", "1" }, .{ "B", "two words" }, .{ "C", "" }, .{ "D", "a#b" } });
}

test "quotes keep whitespace and concatenate" {
    try expectEntries(
        \\A="  padded  "
        \\B='single $x'
        \\C=pre"mid dle"post
        \\D="a" 'b'
        \\
    , &.{ .{ "A", "  padded  " }, .{ "B", "single $x" }, .{ "C", "premid dlepost" }, .{ "D", "a b" } });
}

test "escapes" {
    try expectEntries(
        \\A=a\ b\#c\\d
        \\B="q\"uote \$x \n"
        \\C='it\'s'
        \\
    , &.{ .{ "A", "a b#c\\d" }, .{ "B", "q\"uote $x \\n" }, .{ "C", "it's" } });
}

test "continuation and multi-line quotes" {
    try expectEntries("A=one\\\ntwo\nB=\"line1\nline2\"\nC=x\\\r\ny\r\nD=z\n", &.{
        .{ "A", "onetwo" },
        .{ "B", "line1\nline2" },
        .{ "C", "xy" },
        .{ "D", "z" },
    });
    try expectEntries("# c1 \\\nstill comment\nA=1\n", &.{.{ "A", "1" }});
}

test "invalid keys are skipped" {
    try expectEntries(
        \\export FOO=bar
        \\1BAD=x
        \\A-B=y
        \\NOEQUALS
        \\=empty
        \\OK=1
        \\
    , &.{.{ "OK", "1" }});
}

test "last line without a newline and repeated names" {
    try expectEntries("A=1\nA=2\nB=end", &.{ .{ "A", "1" }, .{ "A", "2" }, .{ "B", "end" } });
}

test "unterminated quote is an error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnterminatedQuote, parse(arena.allocator(), "A=\"open\n"));
    try std.testing.expectError(error.UnterminatedQuote, parse(arena.allocator(), "A='open"));
}
