//! Unit names: validation, type suffixes, template/instance split and glob matching.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_len = 255;

pub const Type = enum {
    service,
    timer,
    target,
    socket,
    path,
    mount,
    automount,
    swap,
    device,
    slice,
    scope,

    /// Suffix without the leading dot.
    pub fn suffix(t: Type) []const u8 {
        return @tagName(t);
    }

    pub fn fromSuffix(s: []const u8) ?Type {
        return std.meta.stringToEnum(Type, s);
    }
};

pub const Error = error{InvalidName} || Allocator.Error;

pub const Name = struct {
    /// Normalized name including the type suffix.
    full: []const u8,
    kind: Type,
    /// Part before `@`, or the whole base name when there is no `@`.
    prefix: []const u8,
    /// Null for plain units, empty for templates, non-empty for instances.
    instance: ?[]const u8,

    pub fn isTemplate(n: Name) bool {
        return if (n.instance) |i| i.len == 0 else false;
    }

    pub fn isInstance(n: Name) bool {
        return if (n.instance) |i| i.len > 0 else false;
    }

    /// Name without the type suffix.
    pub fn base(n: Name) []const u8 {
        return n.full[0 .. n.full.len - n.kind.suffix().len - 1];
    }

    /// `foo@.service` for an instance, null for other names.
    pub fn templateName(n: Name, gpa: Allocator) Allocator.Error!?[]const u8 {
        if (!n.isInstance()) return null;
        return try std.fmt.allocPrint(gpa, "{s}@.{s}", .{ n.prefix, n.kind.suffix() });
    }

    pub fn format(n: Name, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(n.full);
    }
};

pub fn isValidChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        ':', '_', '.', '-', '@', '\\' => true,
        else => false,
    };
}

/// Parses a unit name as typed on the command line. A name without a known type suffix is a
/// `.service`.
pub fn parse(gpa: Allocator, input: []const u8) Error!Name {
    if (input.len == 0 or input.len > max_len) return error.InvalidName;
    if (std.mem.eql(u8, input, ".") or std.mem.eql(u8, input, "..")) return error.InvalidName;
    for (input) |c| if (!isValidChar(c)) return error.InvalidName;

    var kind: Type = .service;
    var base_len = input.len;
    var needs_suffix = true;
    if (std.mem.findScalarLast(u8, input, '.')) |dot| {
        if (Type.fromSuffix(input[dot + 1 ..])) |t| {
            kind = t;
            base_len = dot;
            needs_suffix = false;
        }
    }
    const base_name = input[0..base_len];
    if (base_name.len == 0) return error.InvalidName;

    const full = if (needs_suffix)
        try std.fmt.allocPrint(gpa, "{s}.service", .{input})
    else
        try gpa.dupe(u8, input);
    errdefer gpa.free(full);
    if (full.len > max_len) return error.InvalidName;

    const b = full[0..base_len];
    var prefix = b;
    var instance: ?[]const u8 = null;
    if (std.mem.findScalar(u8, b, '@')) |at| {
        prefix = b[0..at];
        const inst = b[at + 1 ..];
        if (std.mem.findScalar(u8, inst, '@') != null) return error.InvalidName;
        instance = inst;
    }
    if (prefix.len == 0) return error.InvalidName;
    if (std.mem.eql(u8, prefix, ".") or std.mem.eql(u8, prefix, "..")) return error.InvalidName;
    return .{ .full = full, .kind = kind, .prefix = prefix, .instance = instance };
}

pub fn hasGlob(s: []const u8) bool {
    return std.mem.findAny(u8, s, "*?[") != null;
}

/// Shell-style match: `*`, `?`, `[set]`, `[!set]`/`[^set]` and ranges. A `[` without a closing
/// `]` matches itself.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pattern.len) {
            switch (pattern[p]) {
                '*' => {
                    star_p = p;
                    star_t = t;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    t += 1;
                    continue;
                },
                '[' => if (matchClass(pattern, p, text[t])) |r| {
                    if (r.matched) {
                        p = r.next;
                        t += 1;
                        continue;
                    }
                } else if (text[t] == '[') {
                    p += 1;
                    t += 1;
                    continue;
                },
                else => |c| if (c == text[t]) {
                    p += 1;
                    t += 1;
                    continue;
                },
            }
        }
        const sp = star_p orelse return false;
        star_t += 1;
        t = star_t;
        p = sp + 1;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const ClassResult = struct { matched: bool, next: usize };

/// Evaluates the bracket expression starting at `pattern[start] == '['`; null when unterminated.
fn matchClass(pattern: []const u8, start: usize, c: u8) ?ClassResult {
    var i = start + 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len) {
        if (pattern[i] == ']' and !first) return .{ .matched = matched != negate, .next = i + 1 };
        first = false;
        const lo = pattern[i];
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            const hi = pattern[i + 2];
            if (lo <= c and c <= hi) matched = true;
            i += 3;
        } else {
            if (lo == c) matched = true;
            i += 1;
        }
    }
    return null;
}

const testing = std.testing;

fn parseT(arena: Allocator, s: []const u8) !Name {
    return parse(arena, s);
}

test "plain names default to service" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const n = try parseT(arena.allocator(), "foo");
    try testing.expectEqualStrings("foo.service", n.full);
    try testing.expectEqual(Type.service, n.kind);
    try testing.expectEqualStrings("foo", n.prefix);
    try testing.expectEqual(@as(?[]const u8, null), n.instance);
    try testing.expectEqualStrings("foo", n.base());
    try testing.expect(!n.isTemplate() and !n.isInstance());
}

test "all type suffixes are recognized" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (std.meta.tags(Type)) |t| {
        const input = try std.fmt.allocPrint(arena.allocator(), "x.{s}", .{@tagName(t)});
        const n = try parseT(arena.allocator(), input);
        try testing.expectEqualStrings(input, n.full);
        try testing.expectEqual(t, n.kind);
        try testing.expectEqualStrings("x", n.base());
    }
}

test "unknown suffix is part of a service name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const n = try parseT(arena.allocator(), "dbus-org.freedesktop.Foo");
    try testing.expectEqualStrings("dbus-org.freedesktop.Foo.service", n.full);
    try testing.expectEqual(Type.service, n.kind);
}

test "templates and instances" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inst = try parseT(a, "foo@bar.service");
    try testing.expect(inst.isInstance());
    try testing.expectEqualStrings("foo", inst.prefix);
    try testing.expectEqualStrings("bar", inst.instance.?);
    try testing.expectEqualStrings("foo@.service", (try inst.templateName(a)).?);
    const tmpl = try parseT(a, "foo@.timer");
    try testing.expect(tmpl.isTemplate());
    try testing.expectEqual(Type.timer, tmpl.kind);
    try testing.expectEqual(@as(?[]const u8, null), try tmpl.templateName(a));
    const bare = try parseT(a, "getty@tty1");
    try testing.expectEqualStrings("getty@tty1.service", bare.full);
    try testing.expectEqualStrings("tty1", bare.instance.?);
}

test "invalid names are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_][]const u8{
        "",              ".",         "..", "a/b", "/etc/foo", "../x", "foo bar", "foo$", ".service", "@.service",
        "a@b@c.service",
        "föö",
        "foo\n",         "..service",
    };
    for (bad) |b| try testing.expectError(error.InvalidName, parse(a, b));
}

test "length limit applies to the normalized name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try std.fmt.allocPrint(a, "{s}.service", .{try letters(a, 247)});
    _ = try parse(a, ok);
    try testing.expectError(error.InvalidName, parse(a, try letters(a, 256)));
    try testing.expectError(error.InvalidName, parse(a, try letters(a, 250)));
    const timer = try std.fmt.allocPrint(a, "{s}.timer", .{try letters(a, 250)});
    try testing.expectError(error.InvalidName, parse(a, timer));
}

fn letters(a: Allocator, n: usize) ![]u8 {
    const s = try a.alloc(u8, n);
    @memset(s, 'a');
    return s;
}

test "backslash and colon are valid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const n = try parseT(arena.allocator(), "dev-disk-by\\x2dlabel:x.service");
    try testing.expectEqualStrings("dev-disk-by\\x2dlabel:x", n.base());
}

test "format prints the full name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const n = try parseT(arena.allocator(), "foo");
    const s = try std.fmt.allocPrint(arena.allocator(), "{f}", .{n});
    try testing.expectEqualStrings("foo.service", s);
}

test "glob matching" {
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("foo-*", "foo-bar.service"));
    try testing.expect(globMatch("*.service", "a.service"));
    try testing.expect(!globMatch("*.service", "a.timer"));
    try testing.expect(globMatch("f?o", "foo"));
    try testing.expect(!globMatch("f?o", "fo"));
    try testing.expect(globMatch("[abc]x", "bx"));
    try testing.expect(!globMatch("[abc]x", "dx"));
    try testing.expect(globMatch("[!abc]x", "dx"));
    try testing.expect(globMatch("[^abc]x", "dx"));
    try testing.expect(globMatch("[a-c]x", "cx"));
    try testing.expect(!globMatch("[a-c]x", "dx"));
    try testing.expect(globMatch("[]]", "]"));
    try testing.expect(globMatch("a[", "a["));
    try testing.expect(globMatch("a*b*c", "aXXbYYc"));
    try testing.expect(!globMatch("a*b*c", "aXXbYY"));
    try testing.expect(globMatch("a**", "a"));
    try testing.expect(!globMatch("abc", "abcd"));
    try testing.expect(!globMatch("", "a"));
    try testing.expect(hasGlob("a*") and hasGlob("a?") and hasGlob("[a]") and !hasGlob("abc"));
}
