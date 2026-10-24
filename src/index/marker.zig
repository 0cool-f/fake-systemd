// SPDX-License-Identifier: GPL-3.0-or-later
//! Marker block in generated files (§6.6) and the `fake-systemd.meta` variant for formats
//! without comments. A comment marker starts at offset 0 or right after one leading `#!` line.
const std = @import("std");
const Io = std.Io;
const hash = @import("hash.zig");

pub const header_line = "# Generated automatically by fake-systemd. Remove this block to take ownership of the file.";
pub const meta_name = "fake-systemd.meta";

pub const Marker = struct {
    /// Unit name, including a template instance (`foo@bar.service`).
    unit: []const u8,
    source: []const u8,
    source_hash: u64,
    body_hash: u64,
    generator: []const u8,
};

pub const Parsed = struct {
    marker: Marker,
    /// Leading `#!` line including its newline; empty when absent.
    shebang: []const u8,
    /// Content after the marker block.
    rest: []const u8,

    /// Hash of the body as generated: shebang line followed by the rest, marker excluded.
    pub fn bodyHash(p: Parsed) u64 {
        return hash.bodyHashSplit(p.shebang, p.rest);
    }

    /// True when the recorded `Body-Hash` still matches the body on disk.
    pub fn bodyIntact(p: Parsed) bool {
        return p.bodyHash() == p.marker.body_hash;
    }

    /// The body as the generator produced it; caller frees.
    pub fn bodyAlloc(p: Parsed, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.mem.concat(gpa, u8, &.{ p.shebang, p.rest });
    }
};

pub const WriteError = error{ InvalidField, OutOfMemory };

fn plainField(s: []const u8) bool {
    return std.mem.findAny(u8, s, "\r\n") == null;
}

pub fn write(w: *Io.Writer, m: Marker) Io.Writer.Error!void {
    try w.print(
        "{s}\n# Unit: {s}\n# Source: {s}\n# Source-Hash: {f}\n# Body-Hash: {f}\n# Generator: {s}\n",
        .{ header_line, m.unit, m.source, hash.str(m.source_hash), hash.str(m.body_hash), m.generator },
    );
}

/// Returns `body` with the marker block inserted (after a leading `#!` line if the body has
/// one); `Body-Hash` covers `body` as given.
pub fn compose(gpa: std.mem.Allocator, unit: []const u8, source: []const u8, source_hash: u64, generator: []const u8, body: []const u8) WriteError![]u8 {
    if (!plainField(unit) or !plainField(source) or !plainField(generator)) return error.InvalidField;
    var split: usize = 0;
    if (std.mem.startsWith(u8, body, "#!")) {
        if (std.mem.findScalar(u8, body, '\n')) |i| split = i + 1;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    aw.writer.writeAll(body[0..split]) catch return error.OutOfMemory;
    write(&aw.writer, .{
        .unit = unit,
        .source = source,
        .source_hash = source_hash,
        .body_hash = hash.bodyHash(body),
        .generator = generator,
    }) catch return error.OutOfMemory;
    aw.writer.writeAll(body[split..]) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const Lines = struct {
    rest: []const u8,

    fn next(l: *Lines) ?[]const u8 {
        if (l.rest.len == 0) return null;
        const end = std.mem.findScalar(u8, l.rest, '\n') orelse return null;
        const line = l.rest[0..end];
        l.rest = l.rest[end + 1 ..];
        return line;
    }

    fn field(l: *Lines, key: []const u8) ?[]const u8 {
        const line = l.next() orelse return null;
        if (!std.mem.startsWith(u8, line, key)) return null;
        return line[key.len..];
    }
};

/// Parses the marker block; null when it is absent or incomplete.
pub fn parse(content: []const u8) ?Parsed {
    var shebang: []const u8 = "";
    var start = content;
    if (std.mem.startsWith(u8, content, "#!")) {
        const i = std.mem.findScalar(u8, content, '\n') orelse return null;
        shebang = content[0 .. i + 1];
        start = content[i + 1 ..];
    }
    var l: Lines = .{ .rest = start };
    const first = l.next() orelse return null;
    if (!std.mem.eql(u8, first, header_line)) return null;
    const unit = l.field("# Unit: ") orelse return null;
    const source = l.field("# Source: ") orelse return null;
    const source_hash = hash.parse(l.field("# Source-Hash: ") orelse return null) orelse return null;
    const body_hash = hash.parse(l.field("# Body-Hash: ") orelse return null) orelse return null;
    const generator = l.field("# Generator: ") orelse return null;
    return .{
        .marker = .{ .unit = unit, .source = source, .source_hash = source_hash, .body_hash = body_hash, .generator = generator },
        .shebang = shebang,
        .rest = l.rest,
    };
}

/// Version token of `fake-systemd <version> <backend>/<n>`; empty when the line is malformed.
pub fn generatorVersion(generator: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, generator, ' ');
    _ = it.next() orelse return "";
    return it.next() orelse "";
}

pub const BodyEntry = struct {
    path: []const u8,
    hash: u64,
};

pub const Meta = struct {
    unit: []const u8,
    source: []const u8,
    source_hash: u64,
    generator: []const u8,
    /// One entry per generated file, path relative to the service directory.
    bodies: []const BodyEntry,
};

pub fn writeMeta(w: *Io.Writer, m: Meta) (Io.Writer.Error || error{InvalidField})!void {
    if (!plainField(m.unit) or !plainField(m.source) or !plainField(m.generator)) return error.InvalidField;
    for (m.bodies) |b| if (!plainField(b.path)) return error.InvalidField;
    try w.print("{s}\nUnit: {s}\nSource: {s}\nSource-Hash: {f}\nGenerator: {s}\n", .{
        header_line, m.unit, m.source, hash.str(m.source_hash), m.generator,
    });
    for (m.bodies) |b| try w.print("Body-Hash: {s} {f}\n", .{ b.path, hash.str(b.hash) });
}

/// Parses a meta file; slices point into `content`, `bodies` is allocated from `gpa`.
pub fn parseMeta(gpa: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!?Meta {
    var lines = std.mem.splitScalar(u8, content, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.eql(u8, first, header_line)) return null;
    var unit: ?[]const u8 = null;
    var source: ?[]const u8 = null;
    var source_hash: ?u64 = null;
    var generator: ?[]const u8 = null;
    var bodies: std.ArrayList(BodyEntry) = .empty;
    errdefer bodies.deinit(gpa);
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Unit: ")) {
            unit = line["Unit: ".len..];
        } else if (std.mem.startsWith(u8, line, "Source: ")) {
            source = line["Source: ".len..];
        } else if (std.mem.startsWith(u8, line, "Source-Hash: ")) {
            source_hash = hash.parse(line["Source-Hash: ".len..]) orelse return null;
        } else if (std.mem.startsWith(u8, line, "Generator: ")) {
            generator = line["Generator: ".len..];
        } else if (std.mem.startsWith(u8, line, "Body-Hash: ")) {
            const v = line["Body-Hash: ".len..];
            const sp = std.mem.findScalarLast(u8, v, ' ') orelse return null;
            const h = hash.parse(v[sp + 1 ..]) orelse return null;
            try bodies.append(gpa, .{ .path = v[0..sp], .hash = h });
        }
    }
    if (unit == null or source == null or source_hash == null or generator == null) return null;
    return .{
        .unit = unit.?,
        .source = source.?,
        .source_hash = source_hash.?,
        .generator = generator.?,
        .bodies = try bodies.toOwnedSlice(gpa),
    };
}

const testing = std.testing;

test "compose renders the exact six-line block" {
    const out = try compose(testing.allocator, "foo@bar.service", "/usr/lib/systemd/system/foo@.service", 0x7d1f0c2a9b3e4f51, "fake-systemd 0.1.0 dinit/1", "type = process\n");
    defer testing.allocator.free(out);
    var expected: [512]u8 = undefined;
    const want = try std.fmt.bufPrint(&expected,
        \\# Generated automatically by fake-systemd. Remove this block to take ownership of the file.
        \\# Unit: foo@bar.service
        \\# Source: /usr/lib/systemd/system/foo@.service
        \\# Source-Hash: xxh3:7d1f0c2a9b3e4f51
        \\# Body-Hash: {f}
        \\# Generator: fake-systemd 0.1.0 dinit/1
        \\type = process
        \\
    , .{hash.str(hash.bodyHash("type = process\n"))});
    try testing.expectEqualStrings(want, out);
}

test "parse round-trips and splits header from body" {
    const out = try compose(testing.allocator, "foo.service", "/s/foo.service", 1, "fake-systemd 0.1.0 dinit/1", "a\nb\n");
    defer testing.allocator.free(out);
    const p = parse(out).?;
    try testing.expectEqualStrings("foo.service", p.marker.unit);
    try testing.expectEqualStrings("/s/foo.service", p.marker.source);
    try testing.expectEqual(@as(u64, 1), p.marker.source_hash);
    try testing.expectEqualStrings("", p.shebang);
    try testing.expectEqualStrings("a\nb\n", p.rest);
    try testing.expect(p.bodyIntact());
    try testing.expectEqualStrings("0.1.0", generatorVersion(p.marker.generator));
}

test "shebang is emitted before the marker and the body round-trips" {
    const body = "#!/bin/sh\nexec foo\n";
    const out = try compose(testing.allocator, "foo.service", "/s/foo.service", 1, "g", body);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "#!/bin/sh\n" ++ header_line ++ "\n# Unit: foo.service\n"));
    const p = parse(out).?;
    try testing.expectEqualStrings("#!/bin/sh\n", p.shebang);
    try testing.expectEqualStrings("exec foo\n", p.rest);
    try testing.expectEqual(hash.bodyHash(body), p.marker.body_hash);
    try testing.expect(p.bodyIntact());
    const joined = try p.bodyAlloc(testing.allocator);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(body, joined);
}

test "edited body is detected with and without shebang" {
    for ([_][]const u8{ "#!/bin/sh\nexec foo\n", "a\n" }) |body| {
        const out = try compose(testing.allocator, "foo.service", "/s/foo.service", 1, "g", body);
        defer testing.allocator.free(out);
        const edited = try std.mem.concat(testing.allocator, u8, &.{ out, "extra\n" });
        defer testing.allocator.free(edited);
        try testing.expect(parse(out).?.bodyIntact());
        try testing.expect(!parse(edited).?.bodyIntact());
    }
    const out = try compose(testing.allocator, "foo.service", "/s/foo.service", 1, "g", "#!/bin/sh\nx\n");
    defer testing.allocator.free(out);
    out[2] = 'X';
    try testing.expect(!parse(out).?.bodyIntact());
}

test "a shebang line not followed by the marker gives null" {
    try testing.expect(parse("#!/bin/sh\nexec foo\n") == null);
    try testing.expect(parse("#!/bin/sh\n") == null);
    try testing.expect(parse("#!/bin/sh") == null);
    const out = try compose(testing.allocator, "foo.service", "/s/foo.service", 1, "g", "a\n");
    defer testing.allocator.free(out);
    const two = try std.mem.concat(testing.allocator, u8, &.{ "#!/a\n#!/b\n", out });
    defer testing.allocator.free(two);
    try testing.expect(parse(two) == null);
}

test "parse rejects absent, non-leading, truncated and corrupt blocks" {
    const out = try compose(testing.allocator, "foo.service", "/s/foo.service", 1, "g", "a\n");
    defer testing.allocator.free(out);
    try testing.expect(parse("") == null);
    try testing.expect(parse("type = process\n") == null);
    const shifted = try std.mem.concat(testing.allocator, u8, &.{ "# x\n", out });
    defer testing.allocator.free(shifted);
    try testing.expect(parse(shifted) == null);
    const cut = std.mem.findScalarLast(u8, out[0 .. out.len - 3], '\n').?;
    try testing.expect(parse(out[0..cut]) == null);
    const bad = try testing.allocator.dupe(u8, out);
    defer testing.allocator.free(bad);
    const at = std.mem.find(u8, bad, "xxh3:").?;
    bad[at + 5] = 'Z';
    try testing.expect(parse(bad) == null);
}

test "compose rejects fields with newlines" {
    try testing.expectError(error.InvalidField, compose(testing.allocator, "u", "/a\nb", 1, "g", ""));
    try testing.expectError(error.InvalidField, compose(testing.allocator, "u\r", "/a", 1, "g", ""));
}

test "meta round-trip with several body hashes" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeMeta(&aw.writer, .{
        .unit = "foo@bar.service",
        .source = "/s/foo@.service",
        .source_hash = 0xaa,
        .generator = "fake-systemd 0.1.0 s6-rc/1",
        .bodies = &.{ .{ .path = "run", .hash = 1 }, .{ .path = "dependencies.d/a b", .hash = 2 } },
    });
    const m = (try parseMeta(testing.allocator, aw.written())).?;
    defer testing.allocator.free(m.bodies);
    try testing.expectEqualStrings("foo@bar.service", m.unit);
    try testing.expectEqualStrings("/s/foo@.service", m.source);
    try testing.expectEqual(@as(u64, 0xaa), m.source_hash);
    try testing.expectEqual(@as(usize, 2), m.bodies.len);
    try testing.expectEqualStrings("dependencies.d/a b", m.bodies[1].path);
    try testing.expectEqual(@as(u64, 2), m.bodies[1].hash);
    try testing.expect(try parseMeta(testing.allocator, "Source: x\n") == null);
    try testing.expectError(error.InvalidField, writeMeta(&aw.writer, .{ .unit = "a\nb", .source = "s", .source_hash = 1, .generator = "g", .bodies = &.{} }));
}
