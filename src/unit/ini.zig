//! Parser for the systemd unit-file syntax: sections, `Key=Value` lines, `#`/`;` comment lines
//! and trailing-backslash line continuation.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    section: []const u8,
    key: []const u8,
    value: []const u8,
    file: u32,
    /// First physical line of the assignment, 1-based.
    line: u32,
};

pub const Section = struct {
    name: []const u8,
    file: u32,
    line: u32,
};

pub const ProblemKind = enum {
    assignment_outside_section,
    missing_equals,
    invalid_section_header,
    empty_key,
};

pub const Problem = struct {
    kind: ProblemKind,
    file: u32,
    line: u32,
};

/// Ordered result of parsing one or more files. Slices point into the parsed sources or into
/// allocations made with the allocator given to `parse`, so both must outlive the document.
pub const Document = struct {
    entries: std.ArrayList(Entry) = .empty,
    sections: std.ArrayList(Section) = .empty,
    problems: std.ArrayList(Problem) = .empty,

    pub const empty: Document = .{};

    pub fn hasSection(doc: Document, name: []const u8) bool {
        for (doc.sections.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return true;
        }
        return false;
    }
};

const blank = " \t\r";

/// Appends the entries of `source` to `doc`, tagging them with `file`.
pub fn parse(gpa: Allocator, doc: *Document, source: []const u8, file: u32) Allocator.Error!void {
    var section: ?[]const u8 = null;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var in_continuation = false;
    var start_line: u32 = 0;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const right = std.mem.trimEnd(u8, raw, blank);
        const left = std.mem.trimStart(u8, right, blank);
        const is_comment = left.len > 0 and (left[0] == '#' or left[0] == ';');
        if (is_comment) continue;
        if (!in_continuation and left.len == 0) continue;
        const continues = right.len > 0 and right[right.len - 1] == '\\';
        if (!in_continuation and !continues) {
            try handleLine(gpa, doc, &section, left, file, line_no);
            continue;
        }
        if (!in_continuation) {
            pending.clearRetainingCapacity();
            start_line = line_no;
            in_continuation = true;
            try pending.appendSlice(gpa, if (continues) left[0 .. left.len - 1] else left);
        } else {
            try pending.appendSlice(gpa, if (continues) right[0 .. right.len - 1] else right);
        }
        if (continues) {
            try pending.append(gpa, ' ');
        } else {
            in_continuation = false;
            const joined = try gpa.dupe(u8, std.mem.trimStart(u8, pending.items, blank));
            try handleLine(gpa, doc, &section, joined, file, start_line);
        }
    }
    if (in_continuation) {
        const joined = try gpa.dupe(u8, std.mem.trimStart(u8, pending.items, blank));
        try handleLine(gpa, doc, &section, joined, file, start_line);
    }
}

fn handleLine(
    gpa: Allocator,
    doc: *Document,
    section: *?[]const u8,
    line: []const u8,
    file: u32,
    line_no: u32,
) Allocator.Error!void {
    const text = std.mem.trimEnd(u8, line, blank);
    if (text.len == 0) return;
    if (text[0] == '[') {
        if (text[text.len - 1] != ']' or text.len < 3) {
            section.* = null;
            try doc.problems.append(gpa, .{ .kind = .invalid_section_header, .file = file, .line = line_no });
            return;
        }
        const name = text[1 .. text.len - 1];
        section.* = name;
        try doc.sections.append(gpa, .{ .name = name, .file = file, .line = line_no });
        return;
    }
    const eq = std.mem.findScalar(u8, text, '=') orelse {
        try doc.problems.append(gpa, .{ .kind = .missing_equals, .file = file, .line = line_no });
        return;
    };
    const key = std.mem.trimEnd(u8, text[0..eq], blank);
    if (key.len == 0) {
        try doc.problems.append(gpa, .{ .kind = .empty_key, .file = file, .line = line_no });
        return;
    }
    const current = section.* orelse {
        try doc.problems.append(gpa, .{ .kind = .assignment_outside_section, .file = file, .line = line_no });
        return;
    };
    const value = std.mem.trim(u8, text[eq + 1 ..], blank);
    try doc.entries.append(gpa, .{
        .section = current,
        .key = key,
        .value = value,
        .file = file,
        .line = line_no,
    });
}

const testing = std.testing;

fn parseTest(arena: Allocator, source: []const u8) !Document {
    var doc: Document = .empty;
    try parse(arena, &doc, source, 0);
    return doc;
}

test "sections, keys, trimming and line numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(arena.allocator(),
        \\[Unit]
        \\Description =  Hello world  
        \\
        \\[Service]
        \\ExecStart=/bin/true
        \\Environment="A=b c"
        \\
    );
    try testing.expectEqual(@as(usize, 3), doc.entries.items.len);
    try testing.expectEqualStrings("Unit", doc.entries.items[0].section);
    try testing.expectEqualStrings("Description", doc.entries.items[0].key);
    try testing.expectEqualStrings("Hello world", doc.entries.items[0].value);
    try testing.expectEqual(@as(u32, 2), doc.entries.items[0].line);
    try testing.expectEqualStrings("Service", doc.entries.items[2].section);
    try testing.expectEqualStrings("\"A=b c\"", doc.entries.items[2].value);
    try testing.expectEqual(@as(usize, 0), doc.problems.items.len);
    try testing.expect(doc.hasSection("Service"));
    try testing.expect(!doc.hasSection("Install"));
}

test "comments only at line start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(arena.allocator(),
        \\# top
        \\[Unit]
        \\  ; indented comment
        \\Description=a # not a comment
        \\ # another
        \\After=b;c
        \\
    );
    try testing.expectEqual(@as(usize, 2), doc.entries.items.len);
    try testing.expectEqualStrings("a # not a comment", doc.entries.items[0].value);
    try testing.expectEqualStrings("b;c", doc.entries.items[1].value);
}

test "line continuation joins with a space and skips comments inside" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(
        arena.allocator(),
        "[Service]\nExecStart=/bin/a \\\n  --x \\\n# note\n  --y\nUser=u\n",
    );
    try testing.expectEqual(@as(usize, 2), doc.entries.items.len);
    try testing.expectEqualStrings("/bin/a    --x    --y", doc.entries.items[0].value);
    try testing.expectEqual(@as(u32, 2), doc.entries.items[0].line);
    try testing.expectEqualStrings("User", doc.entries.items[1].key);
    try testing.expectEqual(@as(u32, 6), doc.entries.items[1].line);
}

test "continuation at end of file still yields the entry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(arena.allocator(), "[Unit]\nDescription=abc \\");
    try testing.expectEqual(@as(usize, 1), doc.entries.items.len);
    try testing.expectEqualStrings("abc", doc.entries.items[0].value);
}

test "empty value is kept as an entry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(arena.allocator(), "[Service]\nExecStart=\n");
    try testing.expectEqual(@as(usize, 1), doc.entries.items.len);
    try testing.expectEqualStrings("", doc.entries.items[0].value);
}

test "value may contain equals signs and CRLF endings are trimmed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(arena.allocator(), "[Service]\r\nEnvironment=A=1\r\n");
    try testing.expectEqualStrings("A=1", doc.entries.items[0].value);
}

test "problems are recorded and parsing continues" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseTest(arena.allocator(),
        \\Orphan=1
        \\[Unit
        \\X=1
        \\[Unit]
        \\garbage
        \\=nokey
        \\Ok=1
        \\
    );
    try testing.expectEqual(@as(usize, 1), doc.entries.items.len);
    try testing.expectEqualStrings("Ok", doc.entries.items[0].key);
    try testing.expectEqual(@as(usize, 5), doc.problems.items.len);
    try testing.expectEqual(ProblemKind.assignment_outside_section, doc.problems.items[0].kind);
    try testing.expectEqual(ProblemKind.invalid_section_header, doc.problems.items[1].kind);
    try testing.expectEqual(ProblemKind.assignment_outside_section, doc.problems.items[2].kind);
    try testing.expectEqual(ProblemKind.missing_equals, doc.problems.items[3].kind);
    try testing.expectEqual(ProblemKind.empty_key, doc.problems.items[4].kind);
}

test "repeated sections and multiple files keep order and file index" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var doc: Document = .empty;
    try parse(arena.allocator(), &doc, "[Unit]\nAfter=a\n[Unit]\nAfter=b\n", 0);
    try parse(arena.allocator(), &doc, "[Unit]\nAfter=c\n", 1);
    try testing.expectEqual(@as(usize, 3), doc.entries.items.len);
    try testing.expectEqualStrings("b", doc.entries.items[1].value);
    try testing.expectEqual(@as(u32, 1), doc.entries.items[2].file);
    try testing.expectEqual(@as(usize, 3), doc.sections.items.len);
}
