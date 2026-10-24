//! Variable expansion of command lines (systemd.service(5), "Command lines"). `${VAR}` expands
//! in place and stays inside its word. A word that is exactly `$VAR` is replaced by the value
//! split at whitespace, which can yield no words. `$$` is a literal dollar sign. Unset
//! variables expand to the empty string; a `$VAR` inside a longer word is left as written.
const std = @import("std");
const Allocator = std.mem.Allocator;
const envfile = @import("envfile.zig");

pub const Vars = std.array_hash_map.String([]const u8);

/// Appends the expansion of `word` to `out`. Results are allocated with `gpa`, an arena.
pub fn expandWord(gpa: Allocator, word: []const u8, vars: *const Vars, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (word.len > 1 and word[0] == '$' and envfile.isValidName(word[1..])) {
        const value = vars.get(word[1..]) orelse return;
        var it = std.mem.tokenizeAny(u8, value, " \t\n\r");
        while (it.next()) |part| try out.append(gpa, part);
        return;
    }
    if (std.mem.findScalar(u8, word, '$') == null) return out.append(gpa, word);
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < word.len) {
        const c = word[i];
        if (c != '$' or i + 1 >= word.len) {
            try buf.append(gpa, c);
            i += 1;
            continue;
        }
        const next = word[i + 1];
        if (next == '$') {
            try buf.append(gpa, '$');
            i += 2;
        } else if (next == '{') {
            const close = std.mem.findScalarPos(u8, word, i + 2, '}');
            if (close != null and envfile.isValidName(word[i + 2 .. close.?])) {
                try buf.appendSlice(gpa, vars.get(word[i + 2 .. close.?]) orelse "");
                i = close.? + 1;
            } else {
                try buf.append(gpa, c);
                i += 1;
            }
        } else {
            try buf.append(gpa, c);
            i += 1;
        }
    }
    try out.append(gpa, try buf.toOwnedSlice(gpa));
}

/// Expands every word of `words`; with `no_expand` the words are returned as they are.
pub fn expandWords(gpa: Allocator, words: []const []const u8, vars: *const Vars, no_expand: bool) Allocator.Error![]const []const u8 {
    if (no_expand) return gpa.dupe([]const u8, words);
    var out: std.ArrayList([]const u8) = .empty;
    for (words) |w| try expandWord(gpa, w, vars, &out);
    return out.toOwnedSlice(gpa);
}

fn expectWords(vars: *const Vars, input: []const []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try expandWords(arena.allocator(), input, vars, false);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "braced variables stay one word and braceless ones split" {
    var vars: Vars = .empty;
    defer vars.deinit(std.testing.allocator);
    try vars.put(std.testing.allocator, "OPTS", "-a  -b \"c\"");
    try vars.put(std.testing.allocator, "ONE", "one");
    try expectWords(&vars, &.{ "${OPTS}", "$OPTS" }, &.{ "-a  -b \"c\"", "-a", "-b", "\"c\"" });
    try expectWords(&vars, &.{ "x${ONE}y", "${ONE}${ONE}" }, &.{ "xoney", "oneone" });
}

test "braceless variable inside a word is literal" {
    var vars: Vars = .empty;
    defer vars.deinit(std.testing.allocator);
    try vars.put(std.testing.allocator, "ONE", "one");
    try expectWords(&vars, &.{ "pre$ONE", "$ONEpost" }, &.{"pre$ONE"});
}

test "unset variables" {
    var vars: Vars = .empty;
    defer vars.deinit(std.testing.allocator);
    try expectWords(&vars, &.{ "a", "$NOPE", "b", "${NOPE}", "c${NOPE}" }, &.{ "a", "b", "", "c" });
}

test "dollar escapes and malformed references" {
    var vars: Vars = .empty;
    defer vars.deinit(std.testing.allocator);
    try vars.put(std.testing.allocator, "A", "v");
    try expectWords(&vars, &.{ "$$", "$$A", "cost$$5", "${A", "${}", "${1x}", "$", "a$", "${A:-x}" }, &.{ "$", "$A", "cost$5", "${A", "${}", "${1x}", "$", "a$", "${A:-x}" });
}

test "no_expand keeps everything" {
    var vars: Vars = .empty;
    defer vars.deinit(std.testing.allocator);
    try vars.put(std.testing.allocator, "A", "v");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try expandWords(arena.allocator(), &.{ "$A", "${A}", "$$" }, &vars, true);
    try std.testing.expectEqualStrings("$A", got[0]);
    try std.testing.expectEqualStrings("${A}", got[1]);
    try std.testing.expectEqualStrings("$$", got[2]);
}
