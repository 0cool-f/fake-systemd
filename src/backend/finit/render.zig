// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of a finit `.conf` file (finit.conf(5)) from decisions already taken by the backend:
//! stanza kind, conditions, identity and the helper that runs after the service stopped.
//! The command is always the executor, which logs, applies the unit settings and runs `ExecStop=`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const timespan = @import("../../unit/timespan.zig");
const native = @import("native.zig");

pub const Kind = enum { service, task };

/// `setpriv` switches to the account through the system libc, with its supplementary groups. Finit
/// sets only the primary group of its own `@user:group` option, and only when a group is named.
pub const Wrapper = struct {
    path: []const u8,
    /// A plain account name.
    user: []const u8,
    /// A plain group name; the primary group of `user` when null.
    group: ?[]const u8 = null,
};

/// Flags of `setpriv` that switch the account; the primary group of an account without `Group=` is
/// looked up when the command starts. `quote` selects the quoting of the word that does so: finit
/// joins double-quoted words and expands them itself, a shell script quotes the substitution only.
fn writeWrapperFlags(w: *Io.Writer, wrapper: Wrapper, quote: enum { finit, sh }) Io.Writer.Error!void {
    try w.print(" --reuid={s} ", .{wrapper.user});
    if (wrapper.group) |g| {
        try w.print("--regid={s}", .{g});
    } else switch (quote) {
        .finit => try w.print("\"--regid=$(id -g {s})\"", .{wrapper.user}),
        .sh => try w.print("--regid=\"$(id -g {s})\"", .{wrapper.user}),
    }
    try w.writeAll(" --init-groups");
}

pub const Input = struct {
    unit: *const model.Unit,
    kind: Kind,
    /// Service name finit shows and `initctl` takes.
    service: []const u8,
    executor_path: []const u8,
    /// Command that replaces the executor, for a unit without `ExecStart=`.
    plain_command: ?[]const u8 = null,
    /// The executor stays resident and runs `ExecStop=` when finit signals the service.
    stop_on_signal: bool = false,
    /// The executor writes how the command ended, for the wait of a oneshot.
    record_exit: bool = false,
    /// Conditions, as `service/foo/running`, that gate the start.
    conditions: []const []const u8 = &.{},
    /// `setpriv` in front of the executor, for an account the executor cannot resolve.
    wrapper: ?Wrapper = null,
    /// Script finit runs after the service stopped.
    post_script: ?[]const u8 = null,
    /// The oneshot is `inactive` after it succeeded.
    transient: bool = false,
    /// Comment lines that explain a setting finit cannot honor exactly.
    notes: []const []const u8 = &.{},
};

/// Longest line finit reads, with room for the newline.
pub const max_line = 1000;
/// Finit keeps 63 bytes of a description.
const max_description = 63;
const runlevels = "[2345]";

fn writeDescription(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    var n: usize = 0;
    for (text) |c| {
        if (n >= max_description) break;
        if (c < ' ' or c == 0x7f) continue;
        if (c == '#') {
            if (n + 2 > max_description) break;
            try w.writeAll("\\#");
            n += 2;
            continue;
        }
        try w.writeByte(c);
        n += 1;
    }
}

fn ceilSeconds(usec: u64) u64 {
    return std.math.divCeil(u64, usec, std.time.us_per_s) catch unreachable;
}

/// Seconds finit waits between the stop signal and SIGKILL, from 1 to 60.
pub fn killSeconds(u: *const model.Unit, hooks: bool) ?u64 {
    const us = u.timeout_stop_sec orelse {
        return if (hooks) 60 else null;
    };
    if (us == timespan.infinity) return 60;
    return std.math.clamp(ceilSeconds(us), 1, 60);
}

fn signalName(sig: []const u8) ?[]const u8 {
    const name = std.mem.cutPrefix(u8, sig, "SIG") orelse sig;
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return null;
    if (std.ascii.isDigit(name[0])) return null;
    return name;
}

fn restartWords(w: *Io.Writer, u: *const model.Unit) Io.Writer.Error!void {
    switch (u.restart) {
        .no => try w.writeAll(" norestart"),
        else => try w.writeAll(" restart:always"),
    }
    if (u.restart != .no) {
        if (u.restart_sec) |sec| {
            if (sec != timespan.infinity and sec > 0) try w.print(" restart_sec:{d}", .{ceilSeconds(sec)});
        }
    }
}

fn writeStanza(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.print("{t} {s}", .{ in.kind, runlevels });
    if (in.conditions.len > 0) {
        try w.writeAll(" <");
        for (in.conditions, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(c);
        }
        try w.writeByte('>');
    }
    try w.print(" name:{s}", .{in.service});
    if (in.kind == .service) try restartWords(w, u);
    const hooks = in.stop_on_signal or in.post_script != null;
    if (in.kind == .service) {
        if (killSeconds(u, hooks)) |sec| try w.print(" kill:{d}", .{sec});
        if (u.kill_signal) |sig| {
            if (signalName(sig)) |name| {
                if (!std.mem.eql(u8, name, "TERM")) try w.print(" halt:SIG{s}", .{name});
            }
        }
    }
    if (in.post_script) |path| try w.print(" post:{s}", .{path});
    if (in.plain_command) |command| {
        try w.print(" {s}", .{command});
    } else {
        if (in.wrapper) |wrapper| {
            try w.print(" {s}", .{wrapper.path});
            try writeWrapperFlags(w, wrapper, .finit);
        }
        try w.print(" {s} --exec {s} --log", .{ in.executor_path, u.name.full });
        if (in.stop_on_signal) try w.writeAll(" --stop-on-signal");
        if (in.record_exit) try w.writeAll(" --record-exit");
    }
    try w.writeAll(" -- ");
    try writeDescription(w, u.description orelse u.name.full);
    try w.writeByte('\n');
}

/// The file body: notes and flags as comments, then the stanza.
pub fn renderAlloc(gpa: Allocator, in: Input) (Allocator.Error || error{LineTooLong})![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    for (in.notes) |note| w.print("# {s}\n", .{note}) catch return error.OutOfMemory;
    if (in.transient) w.print("{s} transient\n", .{native.flags_prefix}) catch return error.OutOfMemory;
    const start = aw.written().len;
    writeStanza(w, in) catch return error.OutOfMemory;
    if (aw.written().len - start > max_line) return error.LineTooLong;
    return aw.toOwnedSlice();
}

/// Script that finit runs after the service stopped: it runs `ExecStopPost=` and removes the
/// runtime directories through the executor.
pub fn postScript(gpa: Allocator, unit_name: []const u8, executor_path: []const u8, wrapper: ?Wrapper) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeAll("#!/bin/sh\nexec") catch return error.OutOfMemory;
    if (wrapper) |wr| {
        w.print(" {s}", .{wr.path}) catch return error.OutOfMemory;
        writeWrapperFlags(w, wr, .sh) catch return error.OutOfMemory;
    }
    w.print(" {s} --exec '{s}' --phase stop-post\n", .{ executor_path, unit_name }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;
const name_mod = @import("../../unit/name.zig");

fn testUnit(a: Allocator) !model.Unit {
    return .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
}

test "a service stanza names the service and runs the executor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    u.description = "Foo daemon";
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .service, .service = "foo", .executor_path = "/usr/bin/fake-systemd" });
    try testing.expectEqualStrings("service [2345] name:foo norestart /usr/bin/fake-systemd --exec foo.service --log -- Foo daemon\n", text);
}

test "restart, kill, signal, conditions and identity are stanza options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    u.restart = .always;
    u.restart_sec = 2_500_000;
    u.timeout_stop_sec = 20_000_000;
    u.kill_signal = "SIGUSR1";
    const text = try renderAlloc(a, .{
        .unit = &u,
        .kind = .service,
        .service = "foo",
        .executor_path = "/usr/bin/fake-systemd",
        .stop_on_signal = true,
        .conditions = &.{ "service/db/running", "net/route/default" },
        .wrapper = .{ .path = "/usr/bin/setpriv", .user = "app", .group = "svc" },
        .post_script = "/etc/finit.d/available/foo.stop-post",
    });
    try testing.expectEqualStrings(
        "service [2345] <service/db/running,net/route/default> name:foo restart:always restart_sec:3 kill:20 halt:SIGUSR1 " ++
            "post:/etc/finit.d/available/foo.stop-post /usr/bin/setpriv --reuid=app --regid=svc --init-groups " ++
            "/usr/bin/fake-systemd --exec foo.service --log --stop-on-signal -- foo.service\n",
        text,
    );
}

test "a task has no restart policy and may record its end" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    u.restart = .always;
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .task, .service = "foo", .executor_path = "/x", .record_exit = true, .transient = true, .notes = &.{"a note"} });
    try testing.expectEqualStrings("# a note\n# flags: transient\ntask [2345] name:foo /x --exec foo.service --log --record-exit -- foo.service\n", text);
}

test "kill delay is clamped to the range finit accepts" {
    var u: model.Unit = .{ .name = undefined, .scope = .system };
    try testing.expectEqual(@as(?u64, null), killSeconds(&u, false));
    try testing.expectEqual(@as(?u64, 60), killSeconds(&u, true));
    u.timeout_stop_sec = 100;
    try testing.expectEqual(@as(?u64, 1), killSeconds(&u, false));
    u.timeout_stop_sec = 900_000_000;
    try testing.expectEqual(@as(?u64, 60), killSeconds(&u, false));
    u.timeout_stop_sec = timespan.infinity;
    try testing.expectEqual(@as(?u64, 60), killSeconds(&u, false));
}

test "descriptions lose control characters, escape comments and are cut at 63 bytes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    u.description = "line one\nline # two";
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .task, .service = "foo", .executor_path = "/x" });
    try testing.expect(std.mem.endsWith(u8, text, "-- line oneline \\# two\n"));
    const long_text: [100]u8 = @splat('x');
    u.description = &long_text;
    const cut = try renderAlloc(a, .{ .unit = &u, .kind = .task, .service = "foo", .executor_path = "/x" });
    const want: [63]u8 = @splat('x');
    try testing.expect(std.mem.endsWith(u8, cut, &want ++ "\n"));
}

test "a line longer than finit reads is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    const part: [200]u8 = @splat('d');
    const cond: []const u8 = &part;
    const long = [_][]const u8{ cond, cond, cond, cond, cond };
    try testing.expectError(error.LineTooLong, renderAlloc(a, .{ .unit = &u, .kind = .service, .service = "foo", .executor_path = "/x", .conditions = &long }));
}

test "the stop-post script runs the executor phase, behind the wrapper when there is one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUnit(a);
    const plain = try postScript(a, u.name.full, "/usr/bin/fake-systemd", null);
    try testing.expectEqualStrings("#!/bin/sh\nexec /usr/bin/fake-systemd --exec 'foo.service' --phase stop-post\n", plain);
    const wrapped = try postScript(a, u.name.full, "/usr/bin/fake-systemd", .{ .path = "/usr/bin/setpriv", .user = "ldapuser" });
    try testing.expectEqualStrings(
        "#!/bin/sh\nexec /usr/bin/setpriv --reuid=ldapuser --regid=\"$(id -g ldapuser)\" --init-groups /usr/bin/fake-systemd --exec 'foo.service' --phase stop-post\n",
        wrapped,
    );
}

test "an account without a group has its primary group looked up, quoted for finit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUnit(a);
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .service, .service = "foo", .executor_path = "/x", .wrapper = .{ .path = "/usr/bin/setpriv", .user = "ldapuser" } });
    try testing.expectEqualStrings(
        "service [2345] name:foo norestart /usr/bin/setpriv --reuid=ldapuser \"--regid=$(id -g ldapuser)\" --init-groups /x --exec foo.service --log -- foo.service\n",
        text,
    );
}
