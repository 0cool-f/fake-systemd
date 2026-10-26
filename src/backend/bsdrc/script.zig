// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading shell init scripts for the native-service scan: logical lines, the simple commands of
//! a line with quotes removed, and the expansion of the plain variables a script assigns.
//! Shared by the BSD-style rc and procd backends.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Command = []const []const u8;

pub const Var = struct { name: []const u8, value: []const u8 };

pub fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The first value of `name`: a later assignment is usually in a branch that does not apply.
pub fn lookup(vars: []const Var, name: []const u8) ?[]const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return null;
}

/// Expands `$name`, `${name}`, `${name:-default}` and `${name-default}` from `vars`. Null when a
/// name has no value and no default, or the text uses another form of expansion.
pub fn expand(gpa: Allocator, text: []const u8, vars: []const Var) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '$') {
            try out.append(gpa, text[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) return null;
        var name: []const u8 = undefined;
        var fallback: ?[]const u8 = null;
        if (text[i] == '{') {
            const close = std.mem.findScalarPos(u8, text, i, '}') orelse return null;
            const inner = text[i + 1 .. close];
            const sep = std.mem.findAny(u8, inner, ":-");
            if (sep) |at| {
                name = inner[0..at];
                const tail = inner[at..];
                fallback = if (std.mem.startsWith(u8, tail, ":-")) tail[2..] else if (tail[0] == '-') tail[1..] else return null;
            } else name = inner;
            i = close + 1;
        } else {
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            name = text[start..i];
        }
        if (name.len == 0) return null;
        for (name) |c| if (!isIdent(c)) return null;
        const value = lookup(vars, name) orelse (fallback orelse return null);
        try out.appendSlice(gpa, value);
    }
    return try out.toOwnedSlice(gpa);
}

/// Splits a logical line into the words of each simple command. Quotes are removed, `;`, `&&`,
/// `||`, `|` and `&` end a command, and a `$(...)` or backquoted part stays in its word.
pub fn splitCommands(gpa: Allocator, line: []const u8) Allocator.Error![]const Command {
    var commands: std.ArrayList(Command) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: u8 = 0;
    var depth: usize = 0;
    var backquote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else {
                if (c == '\\' and quote == '"' and i + 1 < line.len and std.mem.findScalar(u8, "\"\\$`", line[i + 1]) != null) {
                    i += 1;
                    try word.append(gpa, line[i]);
                    continue;
                }
                try word.append(gpa, c);
            }
            continue;
        }
        if (depth > 0 or backquote) {
            try word.append(gpa, c);
            if (c == '(') depth += 1;
            if (c == ')' and depth > 0) depth -= 1;
            if (c == '`') backquote = false;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                quote = c;
                in_word = true;
            },
            '\\' => {
                in_word = true;
                if (i + 1 < line.len) {
                    i += 1;
                    try word.append(gpa, line[i]);
                }
            },
            '`' => {
                backquote = true;
                in_word = true;
                try word.append(gpa, c);
            },
            '$' => {
                in_word = true;
                try word.append(gpa, c);
                if (i + 1 < line.len and line[i + 1] == '(') {
                    i += 1;
                    depth = 1;
                    try word.append(gpa, '(');
                }
            },
            ' ', '\t' => if (in_word) {
                try words.append(gpa, try word.toOwnedSlice(gpa));
                in_word = false;
            },
            ';', '|', '&' => {
                // `>&2` and `2>&1` are redirections that stay inside their word.
                if (c == '&' and in_word and word.items.len > 0 and (word.items[word.items.len - 1] == '>' or word.items[word.items.len - 1] == '<')) {
                    try word.append(gpa, c);
                    continue;
                }
                if (in_word) {
                    try words.append(gpa, try word.toOwnedSlice(gpa));
                    in_word = false;
                }
                if (i + 1 < line.len and line[i + 1] == c and c != ';') i += 1;
                if (words.items.len > 0) try commands.append(gpa, try words.toOwnedSlice(gpa));
            },
            '#' => if (!in_word) break else {
                try word.append(gpa, c);
            },
            else => {
                in_word = true;
                try word.append(gpa, c);
            },
        }
    }
    if (in_word) try words.append(gpa, try word.toOwnedSlice(gpa));
    if (words.items.len > 0) try commands.append(gpa, try words.toOwnedSlice(gpa));
    return commands.toOwnedSlice(gpa);
}

/// Index of the `=` of a `NAME=value` word, null for any other word.
pub fn isAssignment(word: []const u8) ?usize {
    var i: usize = 0;
    while (i < word.len and isIdent(word[i])) i += 1;
    return if (i > 0 and i < word.len and word[i] == '=' and !std.ascii.isDigit(word[0])) i else null;
}

const leading_keywords = [_][]const u8{ "if", "then", "else", "elif", "while", "until", "do", "!", "{", "exec", "eval", "time", "command", "export", "readonly", "local", "declare", "nohup", "setsid" };

fn isKeyword(word: []const u8) bool {
    for (leading_keywords) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

pub fn isRedirect(word: []const u8) bool {
    var i: usize = 0;
    while (i < word.len and std.ascii.isDigit(word[i])) i += 1;
    return i < word.len and (word[i] == '<' or word[i] == '>');
}

/// Words of a command without its case-arm label, shell keywords and redirections.
pub fn trimCommand(words: Command) Command {
    var rest = words;
    while (rest.len > 0) {
        const w = rest[0];
        const arm = w.len > 0 and w[w.len - 1] == ')' and std.mem.findScalar(u8, w, '(') == null;
        if (arm or isKeyword(w) or std.mem.eql(u8, w, ";;")) {
            rest = rest[1..];
        } else break;
    }
    return rest;
}

/// The words of `words` before the first redirection.
pub fn withoutRedirects(words: Command) Command {
    for (words, 0..) |w, i| if (isRedirect(w)) return words[0..i];
    return words;
}

/// Reads logical lines: a backslash at the end of a line joins it with the next.
pub const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(l: *Lines, gpa: Allocator) Allocator.Error!?[]const u8 {
        if (l.pos >= l.text.len) return null;
        var out: std.ArrayList(u8) = .empty;
        while (l.pos < l.text.len) {
            const end = std.mem.findScalarPos(u8, l.text, l.pos, '\n') orelse l.text.len;
            const raw = std.mem.trimEnd(u8, l.text[l.pos..end], "\r");
            l.pos = @min(end + 1, l.text.len);
            if (std.mem.endsWith(u8, raw, "\\")) {
                try out.appendSlice(gpa, raw[0 .. raw.len - 1]);
                try out.append(gpa, ' ');
                continue;
            }
            try out.appendSlice(gpa, raw);
            break;
        }
        return try out.toOwnedSlice(gpa);
    }
};

/// Records the variables a line of simple assignments sets; false when the line is not one.
pub fn recordAssignments(gpa: Allocator, words: Command, vars: *std.ArrayList(Var)) Allocator.Error!bool {
    if (words.len == 0 or isAssignment(words[0]) == null) return false;
    for (words) |w| if (isAssignment(w) == null) return false;
    for (words) |w| {
        const eq = isAssignment(w).?;
        const value = (try expand(gpa, w[eq + 1 ..], vars.items)) orelse continue;
        try vars.append(gpa, .{ .name = w[0..eq], .value = value });
    }
    return true;
}

/// True for the absolute path of a program, as opposed to a file or a directory.
pub fn isProgramPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    return std.mem.find(u8, path, "bin/") != null or std.mem.find(u8, path, "libexec/") != null;
}

const testing = std.testing;

test "commands are split at control operators and quotes are removed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cmds = try splitCommands(arena.allocator(), "a 'b c' \"d\\\"e\" && f | g; h &");
    try testing.expectEqual(@as(usize, 4), cmds.len);
    try testing.expectEqualStrings("b c", cmds[0][1]);
    try testing.expectEqualStrings("d\"e", cmds[0][2]);
    try testing.expectEqualStrings("h", cmds[3][0]);
}

test "variables expand with defaults and fail when unknown" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vars = [_]Var{.{ .name = "A", .value = "/usr/sbin" }};
    try testing.expectEqualStrings("/usr/sbin/x", (try expand(a, "$A/x", &vars)).?);
    try testing.expectEqualStrings("/usr/sbin/y", (try expand(a, "${A}/y", &vars)).?);
    try testing.expectEqualStrings("z", (try expand(a, "${B:-z}", &vars)).?);
    try testing.expect((try expand(a, "$B", &vars)) == null);
    try testing.expect((try expand(a, "$(x)", &vars)) == null);
}

test "logical lines join backslash continuations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var l: Lines = .{ .text = "a \\\n b\nc\n" };
    try testing.expectEqualStrings("a   b", (try l.next(arena.allocator())).?);
    try testing.expectEqualStrings("c", (try l.next(arena.allocator())).?);
    try testing.expect((try l.next(arena.allocator())) == null);
}
