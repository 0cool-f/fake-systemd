// SPDX-License-Identifier: GPL-3.0-or-later
//! `/etc/inittab` of BusyBox init: the `runsvdir` entry that tells the system keeps its services
//! as runit service directories, and the block of entries that starts the generated scripts.
//!
//! An entry is `id:runlevels:action:process`; BusyBox ignores the runlevels and reads the id as
//! the terminal. Entries of the block use the actions `wait`, which init runs one after the
//! other at boot in the order of the file, and `shutdown`, which it runs before it stops
//! everything. Neither runs on a reload of the file, so changing the block never starts or stops
//! anything.
const std = @import("std");
const Allocator = std.mem.Allocator;
const execline = @import("../../unit/execline.zig");
const core_block = @import("../../core/block.zig");

pub const begin_marker = "# BEGIN fake-systemd";
pub const end_marker = "# END fake-systemd";

pub const Entry = struct {
    id: []const u8,
    levels: []const u8,
    action: []const u8,
    command: []const u8,
};

/// The fields of an entry; null for a comment, an empty line or a line with fewer than four fields.
pub fn parseEntry(line: []const u8) ?Entry {
    const text = std.mem.trim(u8, line, " \t\r");
    if (text.len == 0 or text[0] == '#') return null;
    const first = std.mem.findScalar(u8, text, ':') orelse return null;
    const second = std.mem.findScalarPos(u8, text, first + 1, ':') orelse return null;
    const third = std.mem.findScalarPos(u8, text, second + 1, ':') orelse return null;
    const command = std.mem.trim(u8, text[third + 1 ..], " \t");
    if (command.len == 0) return null;
    return .{ .id = text[0..first], .levels = text[first + 1 .. second], .action = text[second + 1 .. third], .command = command };
}

/// Actions that keep a process running, which is what `runsvdir` is run as.
fn runsOnItsOwn(action: []const u8) bool {
    return std.mem.eql(u8, action, "respawn") or std.mem.eql(u8, action, "once") or std.mem.eql(u8, action, "askfirst");
}

/// Directory `runsvdir [-P] [-s SCRIPT] DIR` scans: the first word that is not an option or the
/// argument of `-s`.
fn scanDirOf(words: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const w = words[i];
        if (std.mem.eql(u8, w, "-s")) {
            i += 1;
        } else if (w.len > 0 and w[0] != '-') return w;
    }
    return null;
}

/// Directory a `runsvdir` of the inittab scans, null when the file starts none. A command that
/// hands a string to a shell is searched too.
pub fn runsvdirDir(gpa: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const entry = parseEntry(line) orelse continue;
        if (!runsOnItsOwn(entry.action)) continue;
        if (try findRunsvdir(gpa, entry.command, 0)) |dir| return dir;
    }
    return null;
}

fn findRunsvdir(gpa: Allocator, command: []const u8, depth: usize) Allocator.Error!?[]const u8 {
    const words = execline.splitWords(gpa, command) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    for (words, 0..) |w, i| {
        if (std.mem.eql(u8, std.fs.path.basename(w), "runsvdir")) return scanDirOf(words[i + 1 ..]);
        if (depth < 2 and i > 0 and std.mem.findScalar(u8, w, ' ') != null) {
            if (try findRunsvdir(gpa, w, depth + 1)) |dir| return dir;
        }
    }
    return null;
}

// ---- the block of generated services --------------------------------------------------------

/// `<dir>/<service>` and the argument of the entry, when `command` is one of the block.
fn blockService(command: []const u8, script_dir: []const u8, action_word: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, command, ' ');
    const path = it.next() orelse return null;
    const verb = it.next() orelse return null;
    if (it.next() != null or !std.mem.eql(u8, verb, action_word)) return null;
    const rest = std.mem.cutPrefix(u8, path, script_dir) orelse return null;
    const name = std.mem.cutPrefix(u8, rest, "/") orelse return null;
    return if (name.len == 0 or std.mem.findScalar(u8, name, '/') != null) null else name;
}

/// Services of the block, in the order they start; none when the file holds no valid block.
pub fn enabledServices(gpa: Allocator, text: []const u8, script_dir: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const bounds = switch (core_block.locate(text, begin_marker, end_marker)) {
        .block => |b| b,
        .none, .malformed => return out.toOwnedSlice(gpa),
    };
    var lines = std.mem.splitScalar(u8, text[bounds.start..bounds.end], '\n');
    while (lines.next()) |raw| {
        const entry = parseEntry(raw) orelse continue;
        if (!std.mem.eql(u8, entry.action, "wait")) continue;
        if (blockService(entry.command, script_dir, "start")) |name| try out.append(gpa, try gpa.dupe(u8, name));
    }
    return out.toOwnedSlice(gpa);
}

fn writeBlock(w: *std.Io.Writer, services: []const []const u8, script_dir: []const u8) std.Io.Writer.Error!void {
    try w.print("{s}\n", .{begin_marker});
    for (services) |s| try w.print("::wait:{s}/{s} start\n", .{ script_dir, s });
    var i = services.len;
    while (i > 0) : (i -= 1) try w.print("::shutdown:{s}/{s} stop\n", .{ script_dir, services[i - 1] });
    try w.print("{s}\n", .{end_marker});
}

/// `text` with the block listing `services`: replaced where it is, appended when the file has
/// none, and dropped when `services` is empty. Bytes outside the block are kept; a file that
/// does not hold exactly one block fails with `error.MalformedBlock` and `fault` set.
pub fn withServices(gpa: Allocator, text: []const u8, services: []const []const u8, script_dir: []const u8, fault: *core_block.Fault) (core_block.Error || Allocator.Error)![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var text_block: ?[]const u8 = null;
    if (services.len > 0) {
        writeBlock(&aw.writer, services, script_dir) catch return error.OutOfMemory;
        text_block = aw.written();
    }
    return core_block.replace(gpa, text, begin_marker, end_marker, text_block, fault);
}

const testing = std.testing;

fn expectNull(v: anytype) !void {
    try testing.expect(v == null);
}

test "entries have four fields and the command keeps its colons" {
    const e = parseEntry("tty1::respawn:/sbin/getty 38400 tty1").?;
    try testing.expectEqualStrings("tty1", e.id);
    try testing.expectEqualStrings("", e.levels);
    try testing.expectEqualStrings("respawn", e.action);
    try testing.expectEqualStrings("/sbin/getty 38400 tty1", e.command);
    const colon = parseEntry("::sysinit:/bin/sh -c 'a:b'").?;
    try testing.expectEqualStrings("/bin/sh -c 'a:b'", colon.command);
    const levels = parseEntry("id:2345:wait:/etc/rc").?;
    try testing.expectEqualStrings("2345", levels.levels);
    try expectNull(parseEntry("# comment"));
    try expectNull(parseEntry(""));
    try expectNull(parseEntry("::wait:"));
    try expectNull(parseEntry("a:b:c"));
}

test "the directory a runsvdir entry scans is found" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/var/service", (try runsvdirDir(a, "::sysinit:/bin/mkdir -p /var/service\n::respawn:/bin/runsvdir /var/service\n")).?);
    try testing.expectEqualStrings("/etc/service", (try runsvdirDir(a, "# x\nsvc::respawn:/usr/bin/runsvdir -P /etc/service\n")).?);
    try testing.expectEqualStrings("/etc/service", (try runsvdirDir(a, "::respawn:/bin/sh -c 'exec runsvdir /etc/service'\n")).?);
    try testing.expectEqualStrings("/srv", (try runsvdirDir(a, "::once:runsvdir -s /etc/runit/ctrlaltdel /srv\n")).?);
    try expectNull(try runsvdirDir(a, "::sysinit:/etc/init.d/rcS\n::respawn:/sbin/getty 38400 tty1\n"));
    try expectNull(try runsvdirDir(a, "::wait:/bin/runsvdir /var/service\n"));
    try expectNull(try runsvdirDir(a, ""));
}

const block =
    \\::sysinit:/etc/init.d/rcS
    \\# BEGIN fake-systemd
    \\::wait:/etc/init.d/net start
    \\::wait:/etc/init.d/app start
    \\::shutdown:/etc/init.d/app stop
    \\::shutdown:/etc/init.d/net stop
    \\# END fake-systemd
    \\::respawn:/sbin/getty 38400 tty1
    \\
;

test "the services of the block come in the order they start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try enabledServices(arena.allocator(), block, "/etc/init.d");
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("net", got[0]);
    try testing.expectEqualStrings("app", got[1]);
    // Entries outside the block, another directory and other arguments are not part of it.
    const stray = "::wait:/etc/init.d/out start\n# BEGIN fake-systemd\n::wait:/opt/x start\n::wait:/etc/init.d/a/b start\n::wait:/etc/init.d/c restart\n::wait:/etc/init.d/d start\n# END fake-systemd\n";
    const only = try enabledServices(arena.allocator(), stray, "/etc/init.d");
    try testing.expectEqual(@as(usize, 1), only.len);
    try testing.expectEqualStrings("d", only[0]);
}

test "the block is replaced in place, with the stops in the reverse order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fault: core_block.Fault = undefined;
    const out = try withServices(a, block, &.{ "db", "net", "app" }, "/etc/init.d", &fault);
    try testing.expectEqualStrings(
        \\::sysinit:/etc/init.d/rcS
        \\# BEGIN fake-systemd
        \\::wait:/etc/init.d/db start
        \\::wait:/etc/init.d/net start
        \\::wait:/etc/init.d/app start
        \\::shutdown:/etc/init.d/app stop
        \\::shutdown:/etc/init.d/net stop
        \\::shutdown:/etc/init.d/db stop
        \\# END fake-systemd
        \\::respawn:/sbin/getty 38400 tty1
        \\
    , out);
}

test "a file without the block gets it at the end, and an empty list drops it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fault: core_block.Fault = undefined;
    const plain = "::sysinit:/etc/init.d/rcS\n::respawn:/sbin/getty 38400 tty1";
    const added = try withServices(a, plain, &.{"app"}, "/etc/init.d", &fault);
    try testing.expectEqualStrings(
        \\::sysinit:/etc/init.d/rcS
        \\::respawn:/sbin/getty 38400 tty1
        \\# BEGIN fake-systemd
        \\::wait:/etc/init.d/app start
        \\::shutdown:/etc/init.d/app stop
        \\# END fake-systemd
        \\
    , added);
    try testing.expectEqualStrings("::sysinit:/etc/init.d/rcS\n::respawn:/sbin/getty 38400 tty1\n", try withServices(a, added, &.{}, "/etc/init.d", &fault));
    try testing.expectEqualStrings("", try withServices(a, "", &.{}, "/etc/init.d", &fault));
    try testing.expectEqualStrings("# BEGIN fake-systemd\n::wait:/etc/init.d/x start\n::shutdown:/etc/init.d/x stop\n# END fake-systemd\n", try withServices(a, "", &.{"x"}, "/etc/init.d", &fault));
    try testing.expectEqualStrings(block, try withServices(a, block, &.{ "net", "app" }, "/etc/init.d", &fault));
}

test "a block that is not closed exactly once is not rewritten" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fault: core_block.Fault = undefined;
    const open = "::sysinit:/etc/init.d/rcS\n# BEGIN fake-systemd\n::wait:/etc/init.d/net start\n::respawn:/sbin/getty 38400 tty1\n";
    try testing.expectError(error.MalformedBlock, withServices(a, open, &.{"app"}, "/etc/init.d", &fault));
    try testing.expectEqual(@as(usize, 2), fault.line);
    try testing.expectError(error.MalformedBlock, withServices(a, open, &.{}, "/etc/init.d", &fault));
    const nested = "# BEGIN fake-systemd\n# BEGIN fake-systemd\n::wait:/etc/init.d/a start\n# END fake-systemd\n";
    try testing.expectError(error.MalformedBlock, withServices(a, nested, &.{"app"}, "/etc/init.d", &fault));
    try testing.expectEqual(@as(usize, 2), fault.line);
    try testing.expectEqual(@as(usize, 0), (try enabledServices(a, open, "/etc/init.d")).len);
}
