// SPDX-License-Identifier: GPL-3.0-or-later
//! The files of one generated service directory. Scripts carry the marker of fake-systemd as a
//! leading comment; data files that cannot (`type`, `timeout-kill`, `dependencies`, ...) are
//! listed with their hash in a `fake-systemd.meta` file of the directory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const apply = @import("../../reconcile/apply.zig");
const marker = @import("../../index/marker.zig");
const hash = @import("../../index/hash.zig");
const interface = @import("../interface.zig");
const model = @import("../../unit/model.zig");

pub const Set = struct {
    gpa: Allocator,
    unit: []const u8,
    source: []const u8,
    src_hash: u64,
    generator: []const u8,
    /// Absolute path of the service directory.
    dir: []const u8,
    files: std.ArrayList(apply.GeneratedFile) = .empty,
    bodies: std.ArrayList(marker.BodyEntry) = .empty,

    pub fn init(gpa: Allocator, input: interface.GenerateInput, generator: []const u8, dir: []const u8) Set {
        return .{
            .gpa = gpa,
            .unit = input.unit.name.full,
            .source = input.source,
            .src_hash = input.src_hash,
            .generator = generator,
            .dir = dir,
        };
    }

    /// A script with the marker comment, executable unless it is read by an interpreter.
    pub fn script(s: *Set, rel: []const u8, body: []const u8, mode: u16) !void {
        const content = try marker.compose(s.gpa, s.unit, s.source, s.src_hash, s.generator, body);
        try s.files.append(s.gpa, .{ .path = try std.fs.path.join(s.gpa, &.{ s.dir, rel }), .content = content, .mode = mode });
    }

    /// A file without room for a comment, recorded in the meta file.
    pub fn data(s: *Set, rel: []const u8, body: []const u8) !void {
        try s.files.append(s.gpa, .{
            .path = try std.fs.path.join(s.gpa, &.{ s.dir, rel }),
            .style = .meta,
            .content = body,
        });
        try s.bodies.append(s.gpa, .{ .path = rel, .hash = hash.bodyHash(body) });
    }

    /// The files in the order they were added, followed by the meta file when there are data files.
    pub fn done(s: *Set) ![]const apply.GeneratedFile {
        if (s.bodies.items.len > 0) {
            var aw: Io.Writer.Allocating = .init(s.gpa);
            errdefer aw.deinit();
            marker.writeMeta(&aw.writer, .{
                .unit = s.unit,
                .source = s.source,
                .source_hash = s.src_hash,
                .generator = s.generator,
                .bodies = s.bodies.items,
            }) catch return error.OutOfMemory;
            try s.files.append(s.gpa, .{
                .path = try std.fs.path.join(s.gpa, &.{ s.dir, marker.meta_name }),
                .style = .raw,
                .content = try aw.toOwnedSlice(),
            });
        }
        return s.files.items;
    }
};

const testing = std.testing;

test "a service directory lists its data files in a meta file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u: model.Unit = .{ .name = try @import("../../unit/name.zig").parse(a, "foo.service"), .scope = .system };
    var s: Set = .init(a, .{ .unit = &u, .tier = .vendor, .source = "/usr/lib/systemd/system/foo.service", .src_hash = 7 }, "fake-systemd 0.1.0 s6/1", "/etc/s6/sv/foo");
    try s.script("run", "#!/bin/sh\nexec foo\n", 0o755);
    try s.data("timeout-kill", "90000\n");
    const files = try s.done();
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("/etc/s6/sv/foo/run", files[0].path);
    try testing.expectEqual(apply.Style.comment, files[0].style);
    try testing.expect(marker.parse(files[0].content) != null);
    try testing.expectEqual(apply.Style.meta, files[1].style);
    try testing.expectEqualStrings("90000\n", files[1].content);
    try testing.expectEqual(apply.Style.raw, files[2].style);
    const meta = (try marker.parseMeta(a, files[2].content)).?;
    try testing.expectEqualStrings("foo.service", meta.unit);
    try testing.expectEqual(@as(usize, 1), meta.bodies.len);
    try testing.expectEqualStrings("timeout-kill", meta.bodies[0].path);
    try testing.expectEqual(hash.bodyHash("90000\n"), meta.bodies[0].hash);
}

test "scripts alone need no meta file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u: model.Unit = .{ .name = try @import("../../unit/name.zig").parse(a, "foo.service"), .scope = .system };
    var s: Set = .init(a, .{ .unit = &u, .tier = .vendor, .source = "/s", .src_hash = 1 }, "g", "/d");
    try s.script("run", "#!/bin/sh\n", 0o755);
    try testing.expectEqual(@as(usize, 1), (try s.done()).len);
}
