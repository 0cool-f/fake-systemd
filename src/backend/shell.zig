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

/// True for an account or group name that can sit inside a double-quoted word unescaped and that
/// no tool reads as an option, so it does not start with `-`.
pub fn plainAccount(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

/// An account the static executor cannot resolve (it lives in LDAP, sssd, NIS). The executor stays
/// root, which lets it write its state files, and switches to the numeric ids that the script
/// looks up when it runs.
pub const Numeric = struct {
    /// A plain account name.
    user: []const u8,
    /// A plain group name or a number; the primary group of `user` when null.
    group: ?[]const u8 = null,
    /// Plain group names or numbers added to the groups of `user`.
    supplementary: []const []const u8 = &.{},
};

/// True for a name made of digits only, which a user database reads as a number.
pub fn allDigits(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Writes a group as the text of an sh word that stands for its number.
fn writeGroupId(w: *Io.Writer, group: []const u8) Io.Writer.Error!void {
    if (allDigits(group)) return w.writeAll(group);
    try w.print("$(getent group {s} | cut -d: -f3)", .{group});
}

/// Words of a shell that runs the executor given after them with the numeric ids of `n`: `/bin/sh -c
/// 'exec "$0" "$@" --uid ...'`.
pub fn identityPrefix(gpa: std.mem.Allocator, n: Numeric) std.mem.Allocator.Error![]const []const u8 {
    var script: Io.Writer.Allocating = .init(gpa);
    script.writer.writeAll("exec \"$0\" \"$@\"") catch return error.OutOfMemory;
    writeNumericFlags(&script.writer, n) catch return error.OutOfMemory;
    const out = try gpa.alloc([]const u8, 3);
    out[0] = "/bin/sh";
    out[1] = "-c";
    out[2] = script.written();
    return out;
}

/// Writes ` --uid .. --gid .. --groups ..` as sh text: `$(...)` substitutions that ask the
/// system libc for the ids of `n`, so that they follow the account database of the machine.
pub fn writeNumericFlags(w: *Io.Writer, n: Numeric) Io.Writer.Error!void {
    try w.print(" --uid \"$(id -u -- {s})\"", .{n.user});
    if (n.group) |g| {
        try w.writeAll(" --gid ");
        if (allDigits(g)) try w.writeAll(g) else {
            try w.writeByte('"');
            try writeGroupId(w, g);
            try w.writeByte('"');
        }
    } else try w.print(" --gid \"$(id -g -- {s})\"", .{n.user});
    try w.print(" --groups \"$(id -G -- {s} | tr ' ' ,)", .{n.user});
    for (n.supplementary) |g| {
        try w.writeByte(',');
        try writeGroupId(w, g);
    }
    try w.writeByte('"');
}

const testing = std.testing;

test "numeric flags look the ids of the account up when the script runs" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeNumericFlags(&w, .{ .user = "ldapuser" });
    try testing.expectEqualStrings(" --uid \"$(id -u -- ldapuser)\" --gid \"$(id -g -- ldapuser)\" --groups \"$(id -G -- ldapuser | tr ' ' ,)\"", w.buffered());
    w = .fixed(&buf);
    try writeNumericFlags(&w, .{ .user = "ldapuser", .group = "staff", .supplementary = &.{ "audio", "42" } });
    try testing.expectEqualStrings(
        " --uid \"$(id -u -- ldapuser)\" --gid \"$(getent group staff | cut -d: -f3)\" --groups \"$(id -G -- ldapuser | tr ' ' ,),$(getent group audio | cut -d: -f3),42\"",
        w.buffered(),
    );
}

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

test "an account name that starts with a dash is not plain" {
    try testing.expect(plainAccount("svc-dir"));
    try testing.expect(plainAccount("a.b_c"));
    for ([_][]const u8{ "-r", "--", "-u", "-", "" }) |bad| try testing.expect(!plainAccount(bad));
    try testing.expect(allDigits("1000"));
    try testing.expect(!allDigits("1abc"));
    try testing.expect(!allDigits(""));
}
