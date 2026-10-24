// SPDX-License-Identifier: GPL-3.0-or-later
//! Differential tests of `timers.calendar` against `systemd-analyze calendar` (systemd 257)
//! output recorded in `tests/timers/oracle.txt` by `tests/timers/gen.sh`.
const std = @import("std");
const fs = @import("fake_systemd");

const calendar = fs.timers.calendar;
const Tz = fs.exec.tz.Tz;

const oracle = @embedFile("timers/oracle.txt");

const zone_files = [_]struct { name: []const u8, data: []const u8 }{
    .{ .name = "Europe/Rome", .data = @embedFile("timers/zones/Europe_Rome") },
    .{ .name = "America/New_York", .data = @embedFile("timers/zones/America_New_York") },
    .{ .name = "Asia/Tokyo", .data = @embedFile("timers/zones/Asia_Tokyo") },
    .{ .name = "Asia/Kolkata", .data = @embedFile("timers/zones/Asia_Kolkata") },
    .{ .name = "Australia/Lord_Howe", .data = @embedFile("timers/zones/Australia_Lord_Howe") },
    .{ .name = "America/Havana", .data = @embedFile("timers/zones/America_Havana") },
    .{ .name = "UTC", .data = @embedFile("timers/zones/UTC") },
};

fn loadZone(arena: std.mem.Allocator, name: []const u8) !Tz {
    for (zone_files) |z| if (std.mem.eql(u8, z.name, name)) return Tz.parse(arena, z.data);
    return error.UnknownZone;
}

fn zoneKnown(name: []const u8) bool {
    for (zone_files) |z| if (std.mem.eql(u8, z.name, name)) return true;
    return false;
}

test "calendar matches systemd-analyze on the recorded corpus" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var failures: usize = 0;
    var records: usize = 0;
    var rejected: usize = 0;
    var elapses_checked: usize = 0;

    var lines = std.mem.splitScalar(u8, oracle, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const zone = f.next().?;
        const base = try std.fmt.parseInt(i64, f.next().?, 10);
        const expr = f.next().?;
        const norm = f.next().?;
        const list = f.next() orelse "";
        records += 1;

        const local = try loadZone(arena, zone);
        const std_name: ?[]const u8 = if (local.footer) |p| p.std_name else null;
        const dst_name: ?[]const u8 = if (local.footer) |p| p.dst_name orelse p.std_name else null;
        const parsed = calendar.parseOptions(gpa, expr, .{
            .local_names = .{ std_name, dst_name },
            .zone_exists = zoneKnown,
        });

        if (std.mem.eql(u8, norm, "ERR")) {
            rejected += 1;
            if (parsed) |*ok| {
                var spec = ok.*;
                spec.deinit(gpa);
                std.debug.print("accepted but systemd rejects: [{s}] ({s})\n", .{ expr, zone });
                failures += 1;
            } else |_| {}
            continue;
        }

        var spec = parsed catch |e| {
            std.debug.print("rejected but systemd accepts: [{s}] ({s}): {t}\n", .{ expr, zone, e });
            failures += 1;
            continue;
        };
        defer spec.deinit(gpa);

        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try calendar.normalized(spec, &w);
        if (!std.mem.eql(u8, w.buffered(), norm)) {
            std.debug.print("normalized differs: [{s}] got [{s}] want [{s}]\n", .{ expr, w.buffered(), norm });
            failures += 1;
        }

        const tz = if (spec.timezone) |name| try loadZone(arena, name) else local;
        var prev = base * 1_000_000;
        var count: usize = 0;
        var items = if (list.len == 0) std.mem.splitScalar(u8, "", ',') else std.mem.splitScalar(u8, list, ',');
        var bad = false;
        while (list.len > 0) {
            const want_text = items.next() orelse break;
            const want = try std.fmt.parseInt(i64, want_text, 10);
            const got = calendar.next(spec, &tz, prev);
            count += 1;
            elapses_checked += 1;
            if (got == null or @divFloor(got.?, 1_000_000) != want) {
                std.debug.print("elapse #{d} differs: [{s}] ({s}) base {d}: got {?d} want {d}\n", .{
                    count, expr, zone, base, if (got) |g| @divFloor(g, 1_000_000) else null, want,
                });
                bad = true;
                break;
            }
            prev = got.?;
        }
        if (!bad and count < 5) {
            if (calendar.next(spec, &tz, prev)) |extra| {
                std.debug.print("expected no more elapses: [{s}] ({s}) base {d}: got {d}\n", .{ expr, zone, base, @divFloor(extra, 1_000_000) });
                bad = true;
            }
        }
        if (bad) failures += 1;
    }
    if (failures != 0) std.debug.print("calendar oracle: {d} records ({d} rejections), {d} elapses checked, {d} failures\n", .{ records, rejected, elapses_checked, failures });
    try std.testing.expect(records >= 1000 and elapses_checked >= 3000);
    try std.testing.expectEqual(@as(usize, 0), failures);
}
