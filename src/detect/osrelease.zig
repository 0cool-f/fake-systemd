//! `os-release(5)` parsing and loading through `Fs`.
const std = @import("std");
const Fs = @import("../core/Fs.zig");

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const default_id = "linux";

pub const OsRelease = struct {
    /// `ID`, `linux` when absent.
    id: []const u8 = default_id,
    /// `ID_LIKE` split on whitespace, in order.
    id_like: []const []const u8 = &.{},
    /// Every assignment in file order; the last duplicate wins in `get`.
    pairs: []const Pair = &.{},

    pub fn get(os: OsRelease, key: []const u8) ?[]const u8 {
        var i = os.pairs.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, os.pairs[i].key, key)) return os.pairs[i].value;
        }
        return null;
    }
};

/// Parses `content`; allocations (values, lists) come from `gpa`, which is expected to be an arena.
/// Lines that are not valid assignments are skipped.
pub fn parse(gpa: std.mem.Allocator, content: []const u8) error{OutOfMemory}!OsRelease {
    var pairs: std.ArrayList(Pair) = .empty;
    var pos: usize = 0;
    while (pos < content.len) {
        const line_end = std.mem.findScalarPos(u8, content, pos, '\n') orelse content.len;
        const raw = content[pos..line_end];
        pos = line_end + 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (!validKey(key)) continue;
        var rest = std.mem.trimStart(u8, line[eq + 1 ..], " \t");
        var continued: std.ArrayList(u8) = .empty;
        // A trailing backslash outside single quotes joins the next line.
        while (endsWithContinuation(rest) and pos < content.len) {
            try continued.appendSlice(gpa, rest[0 .. rest.len - 1]);
            const next_end = std.mem.findScalarPos(u8, content, pos, '\n') orelse content.len;
            rest = std.mem.trimEnd(u8, content[pos..next_end], "\r");
            pos = next_end + 1;
        }
        const value_src = if (continued.items.len > 0) blk: {
            try continued.appendSlice(gpa, rest);
            break :blk continued.items;
        } else rest;
        const value = try unquote(gpa, value_src);
        try pairs.append(gpa, .{ .key = try gpa.dupe(u8, key), .value = value });
    }
    var os: OsRelease = .{ .pairs = try pairs.toOwnedSlice(gpa) };
    if (os.get("ID")) |id| {
        if (id.len > 0) os.id = id;
    }
    if (os.get("ID_LIKE")) |like| {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, like, " \t");
        while (it.next()) |word| try list.append(gpa, word);
        os.id_like = try list.toOwnedSlice(gpa);
    }
    return os;
}

fn validKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_';
        if (!ok or (i == 0 and std.ascii.isDigit(c))) return false;
    }
    return true;
}

fn endsWithContinuation(text: []const u8) bool {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote == '\'') {
            if (c == '\'') quote = 0;
        } else if (c == '\\') {
            if (i + 1 == text.len) return true;
            i += 1;
        } else if (quote == '"') {
            if (c == '"') quote = 0;
        } else if (c == '\'' or c == '"') {
            quote = c;
        }
    }
    return false;
}

/// Shell-style unquoting: `'..'` literal, `".."` with `\" \\ \$ \`` escapes (other backslashes
/// are kept), unquoted text with `\x` meaning `x`; adjacent segments concatenate.
fn unquote(gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '\'' => {
                const end = std.mem.findScalarPos(u8, text, i + 1, '\'') orelse text.len;
                try out.appendSlice(gpa, text[i + 1 .. end]);
                i = end + 1;
            },
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {
                    if (text[i] == '\\' and i + 1 < text.len) {
                        const n = text[i + 1];
                        if (n == '"' or n == '\\' or n == '$' or n == '`') {
                            try out.append(gpa, n);
                            i += 1;
                            continue;
                        }
                        if (n == '\n') {
                            i += 1;
                            continue;
                        }
                    }
                    try out.append(gpa, text[i]);
                }
                i += 1;
            },
            '\\' => {
                if (i + 1 < text.len) try out.append(gpa, text[i + 1]);
                i += 2;
            },
            '#' => {
                const prev_space = i > 0 and (text[i - 1] == ' ' or text[i - 1] == '\t');
                if (prev_space) break;
                try out.append(gpa, c);
                i += 1;
            },
            else => {
                try out.append(gpa, c);
                i += 1;
            },
        }
    }
    const trimmed = std.mem.trimEnd(u8, out.items, " \t");
    return gpa.dupe(u8, trimmed);
}

pub const paths = [_][]const u8{ "/etc/os-release", "/usr/lib/os-release" };

/// Reads the first existing file of `paths`; no file yields the defaults.
pub fn load(gpa: std.mem.Allocator, fs: *const Fs) !OsRelease {
    for (paths) |path| {
        const content = fs.readFileAlloc(gpa, path, 1 << 20) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => continue,
            else => return e,
        };
        return parse(gpa, content);
    }
    return .{};
}

const testing = std.testing;

fn parseTest(arena: *std.heap.ArenaAllocator, content: []const u8) !OsRelease {
    return parse(arena.allocator(), content);
}

test "plain, double and single quoted values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena,
        \\NAME="Void Linux"
        \\ID=void
        \\PRETTY_NAME='Void Linux'
        \\VERSION_ID=12
        \\
    );
    try testing.expectEqualStrings("Void Linux", os.get("NAME").?);
    try testing.expectEqualStrings("void", os.id);
    try testing.expectEqualStrings("Void Linux", os.get("PRETTY_NAME").?);
    try testing.expectEqualStrings("12", os.get("VERSION_ID").?);
    try testing.expect(os.get("MISSING") == null);
}

test "escapes inside double quotes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena,
        \\A="say \"hi\" \\ \$HOME \` \n"
        \\B='no \"escape\" $here'
        \\C=a\ b\"c
        \\
    );
    try testing.expectEqualStrings("say \"hi\" \\ $HOME ` \\n", os.get("A").?);
    try testing.expectEqualStrings("no \\\"escape\\\" $here", os.get("B").?);
    try testing.expectEqualStrings("a b\"c", os.get("C").?);
}

test "comments, blanks, CRLF, spaces and invalid lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena, "# comment\r\n\r\n  ID = arch  \r\n;semi\r\nnot an assignment\r\n1BAD=x\r\nGOOD=1 # trailing\r\nHASH=a#b\r\n");
    try testing.expectEqualStrings("arch", os.id);
    try testing.expectEqualStrings("1", os.get("GOOD").?);
    try testing.expectEqualStrings("a#b", os.get("HASH").?);
    try testing.expect(os.get("1BAD") == null);
    try testing.expectEqual(@as(usize, 3), os.pairs.len);
}

test "adjacent quoted segments concatenate and quotes may hide hash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena, "X=\"a b\"'c d'e # note\nY=\"#not comment\"\nZ=\n");
    try testing.expectEqualStrings("a bc de", os.get("X").?);
    try testing.expectEqualStrings("#not comment", os.get("Y").?);
    try testing.expectEqualStrings("", os.get("Z").?);
}

test "line continuation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena, "A=one\\\ntwo\nB=\"x\\\ny\"\nC='keep\\\nD=4\n");
    try testing.expectEqualStrings("onetwo", os.get("A").?);
    try testing.expectEqualStrings("xy", os.get("B").?);
    try testing.expectEqualStrings("keep\\", os.get("C").?);
    try testing.expectEqualStrings("4", os.get("D").?);
}

test "the last duplicate wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena, "ID=a\nID=b\n");
    try testing.expectEqualStrings("b", os.id);
}

test "ID defaults to linux" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("linux", (try parseTest(&arena, "NAME=x\n")).id);
    try testing.expectEqualStrings("linux", (try parseTest(&arena, "ID=\n")).id);
    try testing.expectEqualStrings("linux", (try parseTest(&arena, "")).id);
}

test "ID_LIKE is split on whitespace" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const os = try parseTest(&arena, "ID=ubuntu\nID_LIKE=\"debian  other\"\n");
    try testing.expectEqual(@as(usize, 2), os.id_like.len);
    try testing.expectEqualStrings("debian", os.id_like[0]);
    try testing.expectEqualStrings("other", os.id_like[1]);
    try testing.expectEqual(@as(usize, 0), (try parseTest(&arena, "ID=x\n")).id_like.len);
}

test "file without trailing newline" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("alpine", (try parseTest(&arena, "ID=alpine")).id);
}

fn tmpFs(tmp: *testing.TmpDir) Fs {
    return .initDir(testing.io, tmp.dir);
}

test "load prefers /etc and falls back to /usr/lib" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("linux", (try load(a, &fs)).id);
    try fs.makePath("/usr/lib");
    try fs.writeFileAtomic("/usr/lib/os-release", "ID=lib\n", 0o644);
    try testing.expectEqualStrings("lib", (try load(a, &fs)).id);
    try fs.makePath("/etc");
    try fs.writeFileAtomic("/etc/os-release", "ID=etc\n", 0o644);
    try testing.expectEqualStrings("etc", (try load(a, &fs)).id);
}

test "load follows the usual absolute symlink inside the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try fs.makePath("/usr/lib");
    try fs.makePath("/etc");
    try fs.writeFileAtomic("/usr/lib/os-release", "ID=void\n", 0o644);
    try fs.symLink("/usr/lib/os-release", "/etc/os-release");
    try testing.expectEqualStrings("void", (try load(arena.allocator(), &fs)).id);
}
