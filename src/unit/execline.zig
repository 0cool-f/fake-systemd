// SPDX-License-Identifier: GPL-3.0-or-later
//! Exec*= values: command prefixes, systemd word splitting with quotes and C escapes. `$VAR`
//! and `${VAR}` are kept verbatim; expansion belongs to the executor.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ EmptyCommand, MissingArgv0, UnterminatedQuote, InvalidEscape } || Allocator.Error;

pub const Flags = struct {
    /// `-`: failure of the command is ignored.
    ignore_failure: bool = false,
    /// `@`: the second word is `argv[0]`.
    argv0: bool = false,
    /// `:`: no environment variable expansion.
    no_expand: bool = false,
    /// `+`: full privileges, `User=`/`Group=` are not applied.
    plus: bool = false,
    /// `!`: privileged for the exec only.
    bang: bool = false,
    /// `!!`: ambient-capability emulation of `!`.
    bang_bang: bool = false,
};

pub const Command = struct {
    flags: Flags,
    /// `words[0]` is the executable; with `flags.argv0` `words[1]` is `argv[0]`.
    words: []const []const u8,

    pub fn executable(c: Command) []const u8 {
        return c.words[0];
    }

    pub fn argv0(c: Command) []const u8 {
        return if (c.flags.argv0) c.words[1] else c.words[0];
    }

    pub fn args(c: Command) []const []const u8 {
        return c.words[if (c.flags.argv0) 2 else 1..];
    }
};

const whitespace = " \t\n\r";

/// Parses one directive value into its commands; a standalone `;` word separates commands.
pub fn parseAll(gpa: Allocator, value: []const u8) Error![]Command {
    var commands: std.ArrayList(Command) = .empty;
    var pos: usize = 0;
    while (true) {
        skipWhitespace(value, &pos);
        if (pos >= value.len) break;
        const flags = parsePrefixes(value, &pos);
        var words: std.ArrayList([]const u8) = .empty;
        while (try nextWord(gpa, value, &pos)) |word| {
            if (std.mem.eql(u8, word, ";")) break;
            const w = if (std.mem.eql(u8, word, "\\;")) ";" else word;
            try words.append(gpa, w);
        }
        if (words.items.len == 0) return error.EmptyCommand;
        if (flags.argv0 and words.items.len < 2) return error.MissingArgv0;
        try commands.append(gpa, .{ .flags = flags, .words = try words.toOwnedSlice(gpa) });
    }
    if (commands.items.len == 0) return error.EmptyCommand;
    return commands.toOwnedSlice(gpa);
}

/// Splits `value` into words with systemd quoting; used for list-valued settings.
pub fn splitWords(gpa: Allocator, value: []const u8) Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;
    while (try nextWord(gpa, value, &pos)) |word| try words.append(gpa, word);
    return words.toOwnedSlice(gpa);
}

fn skipWhitespace(value: []const u8, pos: *usize) void {
    while (pos.* < value.len and std.mem.findScalar(u8, whitespace, value[pos.*]) != null) pos.* += 1;
}

fn parsePrefixes(value: []const u8, pos: *usize) Flags {
    var flags: Flags = .{};
    while (pos.* < value.len) {
        switch (value[pos.*]) {
            '-' => flags.ignore_failure = true,
            '@' => flags.argv0 = true,
            ':' => flags.no_expand = true,
            '+' => flags.plus = true,
            '!' => if (pos.* + 1 < value.len and value[pos.* + 1] == '!') {
                flags.bang_bang = true;
                pos.* += 1;
            } else {
                flags.bang = true;
            },
            else => break,
        }
        pos.* += 1;
    }
    skipWhitespace(value, pos);
    return flags;
}

/// Returns the next word and advances `pos`; null at the end of input.
fn nextWord(gpa: Allocator, value: []const u8, pos: *usize) Error!?[]const u8 {
    skipWhitespace(value, pos);
    if (pos.* >= value.len) return null;
    var out: std.ArrayList(u8) = .empty;
    var quote: u8 = 0;
    var i = pos.*;
    while (i < value.len) {
        const c = value[i];
        if (c == '\\') {
            i = try unescape(gpa, &out, value, i + 1);
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0 else try out.append(gpa, c);
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (std.mem.findScalar(u8, whitespace, c) != null) {
            break;
        } else {
            try out.append(gpa, c);
        }
        i += 1;
    }
    if (quote != 0) return error.UnterminatedQuote;
    pos.* = i;
    return try out.toOwnedSlice(gpa);
}

/// Decodes the escape whose character (after the backslash) is at `value[at]`; returns the
/// index after it. An unknown escape keeps both the backslash and the character.
fn unescape(gpa: Allocator, out: *std.ArrayList(u8), value: []const u8, at: usize) Error!usize {
    if (at >= value.len) {
        try out.append(gpa, '\\');
        return at;
    }
    const c = value[at];
    const simple: ?u8 = switch (c) {
        'a' => 0x07,
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 0x0b,
        '\\' => '\\',
        '"' => '"',
        '\'' => '\'',
        's' => ' ',
        else => null,
    };
    if (simple) |s| {
        try out.append(gpa, s);
        return at + 1;
    }
    switch (c) {
        'x' => return try numeric(gpa, out, value, at + 1, 2, 16, 8),
        'u' => return try numeric(gpa, out, value, at + 1, 4, 16, 21),
        'U' => return try numeric(gpa, out, value, at + 1, 8, 16, 21),
        '0'...'7' => return try numeric(gpa, out, value, at, 3, 8, 8),
        else => {
            try out.append(gpa, '\\');
            try out.append(gpa, c);
            return at + 1;
        },
    }
}

/// Reads exactly `digits` digits in `radix` starting at `from`; `bits` is 8 for a raw byte or
/// 21 for a Unicode code point.
fn numeric(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    value: []const u8,
    from: usize,
    digits: usize,
    radix: u8,
    bits: u8,
) Error!usize {
    if (from + digits > value.len) return error.InvalidEscape;
    const n = std.fmt.parseInt(u32, value[from .. from + digits], radix) catch return error.InvalidEscape;
    if (n == 0) return error.InvalidEscape;
    if (bits == 8) {
        if (n > 0xff) return error.InvalidEscape;
        try out.append(gpa, @intCast(n));
    } else {
        var buf: [4]u8 = undefined;
        const cp = std.math.cast(u21, n) orelse return error.InvalidEscape;
        const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscape;
        try out.appendSlice(gpa, buf[0..len]);
    }
    return from + digits;
}

const testing = std.testing;

fn one(arena: Allocator, value: []const u8) !Command {
    const all = try parseAll(arena, value);
    try testing.expectEqual(@as(usize, 1), all.len);
    return all[0];
}

fn expectWords(expected: []const []const u8, cmd: Command) !void {
    try testing.expectEqual(expected.len, cmd.words.len);
    for (expected, cmd.words) |e, w| try testing.expectEqualStrings(e, w);
}

test "simple command and arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try one(arena.allocator(), "/usr/bin/foo --bar  baz");
    try expectWords(&.{ "/usr/bin/foo", "--bar", "baz" }, c);
    try testing.expectEqualStrings("/usr/bin/foo", c.executable());
    try testing.expectEqual(@as(usize, 2), c.args().len);
    try testing.expectEqualStrings("/usr/bin/foo", c.argv0());
    try testing.expect(!c.flags.ignore_failure);
}

test "prefixes combine in any order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c1 = try one(a, "-/bin/foo");
    try testing.expect(c1.flags.ignore_failure);
    try expectWords(&.{"/bin/foo"}, c1);
    const c2 = try one(a, "-:+/bin/foo x");
    try testing.expect(c2.flags.ignore_failure and c2.flags.no_expand and c2.flags.plus);
    const c3 = try one(a, "!!/bin/foo");
    try testing.expect(c3.flags.bang_bang and !c3.flags.bang);
    const c4 = try one(a, "!-/bin/foo");
    try testing.expect(c4.flags.bang and c4.flags.ignore_failure and !c4.flags.bang_bang);
    const c5 = try one(a, "@/bin/foo myname arg");
    try testing.expect(c5.flags.argv0);
    try testing.expectEqualStrings("myname", c5.argv0());
    try testing.expectEqualStrings("/bin/foo", c5.executable());
    try expectWords(&.{"arg"}, .{ .flags = .{}, .words = c5.args() });
    const c6 = try one(a, "- /bin/foo");
    try testing.expect(c6.flags.ignore_failure);
    try expectWords(&.{"/bin/foo"}, c6);
}

test "quoting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/bin/sh", "-c", "echo  hi there" }, try one(a, "/bin/sh -c \"echo  hi there\""));
    try expectWords(&.{ "/bin/sh", "-c", "echo 'x' y" }, try one(a, "/bin/sh -c 'echo \\'x\\' y'"));
    try expectWords(&.{ "/bin/foo", "ab cd" }, try one(a, "/bin/foo a\"b c\"d"));
    try expectWords(&.{ "/bin/foo", "", "x" }, try one(a, "/bin/foo \"\" x"));
    try expectWords(&.{ "/bin/foo", "a\"b" }, try one(a, "/bin/foo 'a\"b'"));
}

test "escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/bin/printf", "a\nb\tc\\" }, try one(a, "/bin/printf a\\nb\\tc\\\\"));
    try expectWords(&.{ "/bin/foo", "a b" }, try one(a, "/bin/foo a\\sb"));
    try expectWords(&.{ "/bin/foo", "A" }, try one(a, "/bin/foo \\x41"));
    try expectWords(&.{ "/bin/foo", "A" }, try one(a, "/bin/foo \\101"));
    try expectWords(&.{ "/bin/foo", "\xc3\xa9" }, try one(a, "/bin/foo \\u00e9"));
    try expectWords(&.{ "/bin/foo", "\xf0\x9f\x98\x80" }, try one(a, "/bin/foo \\U0001F600"));
    try expectWords(&.{ "/bin/foo", "\\q" }, try one(a, "/bin/foo \\q"));
    try expectWords(&.{ "/bin/foo", "say \"hi\"" }, try one(a, "/bin/foo \"say \\\"hi\\\"\""));
}

test "variables are kept verbatim" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectWords(
        &.{ "/bin/foo", "$OPTS", "${HOME}/x", "$$", "\\$a" },
        try one(arena.allocator(), "/bin/foo $OPTS ${HOME}/x $$ \\$a"),
    );
}

test "semicolon words separate commands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const all = try parseAll(arena.allocator(), "/bin/a x ; -/bin/b y ; /bin/c");
    try testing.expectEqual(@as(usize, 3), all.len);
    try expectWords(&.{ "/bin/a", "x" }, all[0]);
    try testing.expect(all[1].flags.ignore_failure);
    try expectWords(&.{ "/bin/b", "y" }, all[1]);
    try expectWords(&.{"/bin/c"}, all[2]);
}

test "escaped semicolon is a literal word" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try expectWords(&.{ "/usr/bin/find", ".", "-exec", "x", ";" }, try one(arena.allocator(), "/usr/bin/find . -exec x \\;"));
    try expectWords(&.{ "/bin/foo", "a;b" }, try one(arena.allocator(), "/bin/foo a;b"));
}

test "trailing semicolon is ignored, empty commands are errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try parseAll(a, "/bin/a ;");
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectError(error.EmptyCommand, parseAll(a, "/bin/a ; ; /bin/b"));
    try testing.expectError(error.EmptyCommand, parseAll(a, ""));
    try testing.expectError(error.EmptyCommand, parseAll(a, "   "));
    try testing.expectError(error.EmptyCommand, parseAll(a, "-"));
    try testing.expectError(error.MissingArgv0, parseAll(a, "@/bin/foo"));
}

test "errors in quoting and escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnterminatedQuote, parseAll(a, "/bin/foo \"abc"));
    try testing.expectError(error.UnterminatedQuote, parseAll(a, "/bin/foo 'abc"));
    try testing.expectError(error.InvalidEscape, parseAll(a, "/bin/foo \\xZZ"));
    try testing.expectError(error.InvalidEscape, parseAll(a, "/bin/foo \\x4"));
    try testing.expectError(error.InvalidEscape, parseAll(a, "/bin/foo \\000"));
    try testing.expectError(error.InvalidEscape, parseAll(a, "/bin/foo \\777"));
}

test "splitWords for list settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const w = try splitWords(arena.allocator(), "A=1 \"B=two words\" 'C=3'");
    try testing.expectEqual(@as(usize, 3), w.len);
    try testing.expectEqualStrings("B=two words", w[1]);
    try testing.expectEqual(@as(usize, 0), (try splitWords(arena.allocator(), "  ")).len);
}
