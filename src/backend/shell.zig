// SPDX-License-Identifier: GPL-3.0-or-later
//! Quoting of words for the `sh` scripts that backends generate.
const std = @import("std");
const Io = std.Io;

fn isPlain(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.findScalar(u8, "_-./@%+=:,", c) != null;
}

/// Writes `word` as one shell word. `dollars` turns a `$$` pair into a literal `$`, as systemd
/// does in command lines; otherwise the word is written as it is.
pub fn writeWord(w: *Io.Writer, word: []const u8, dollars: bool) Io.Writer.Error!void {
    var plain = word.len > 0;
    for (word) |c| if (!isPlain(c)) {
        plain = false;
        break;
    };
    if (plain) return w.writeAll(word);
    try w.writeByte('\'');
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        const c = word[i];
        if (c == '\'') {
            try w.writeAll("'\\''");
        } else if (dollars and c == '$' and i + 1 < word.len and word[i + 1] == '$') {
            try w.writeByte('$');
            i += 1;
        } else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// True for an account or group name that can sit inside a double-quoted word unescaped.
pub fn plainAccount(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

const testing = std.testing;

fn expectWord(expected: []const u8, word: []const u8, dollars: bool) !void {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeWord(&w, word, dollars);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "words are quoted for sh" {
    try expectWord("plain", "plain", true);
    try expectWord("/usr/bin/foo", "/usr/bin/foo", true);
    try expectWord("--opt=a:b,c", "--opt=a:b,c", true);
    try expectWord("''", "", true);
    try expectWord("'a b'", "a b", true);
    try expectWord("'it'\\''s'", "it's", true);
    try expectWord("'price$5'", "price$$5", true);
    try expectWord("'price$$5'", "price$$5", false);
    try expectWord("'$HOME'", "$HOME", false);
}
