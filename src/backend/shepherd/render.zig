// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of a Shepherd service file: Scheme that registers one service. The command is always the
//! executor, which logs to the uniform location and applies the unit settings; Shepherd supervises
//! it. The marker sits inside a `#! ... !#` block comment, which Guile reads as a comment.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const timespan = @import("../../unit/timespan.zig");

pub const Kind = enum {
    /// A process that Shepherd supervises.
    daemon,
    /// A command that runs to the end when the service starts; the service stops again.
    oneshot,
    /// A command that runs to the end when the service starts; the service stays started.
    remain,
};

/// `setpriv` switches to the account through the system libc, with its supplementary groups.
/// Shepherd's own `#:user` sets neither the primary group nor the supplementary ones.
pub const Wrapper = struct {
    path: []const u8,
    /// A plain account name.
    user: []const u8,
    /// A plain group name; the primary group of `user`, looked up at registration, when null.
    group: ?[]const u8 = null,
};

pub const Input = struct {
    unit: *const model.Unit,
    kind: Kind,
    service: []const u8,
    executor_path: []const u8,
    /// A command that replaces the executor, for a unit without `ExecStart=`.
    no_command: bool = false,
    /// The executor stays resident and runs `ExecStop=` on the signal of Shepherd, which is sent
    /// to the executor only and not to its group.
    stop_on_signal: bool = false,
    /// `ExecStopPost=` and the removal of runtime directories run after the process stopped.
    stop_post: bool = false,
    /// A started unit that stays started runs the stop phase of the executor when it stops.
    remain_stop: bool = false,
    requirements: []const []const u8 = &.{},
    wrapper: ?Wrapper = null,
    /// The unit runs for a user; its executor takes `--user`.
    user_scope: bool = false,
    /// Comment lines that explain a setting Shepherd cannot honor exactly.
    notes: []const []const u8 = &.{},
};

/// Signals of the stop destructor that Guile defines as `SIG<name>`.
const known_signals = [_][]const u8{ "HUP", "INT", "QUIT", "TERM", "USR1", "USR2", "ALRM", "PIPE", "CONT", "WINCH" };

pub fn signalName(sig: []const u8) ?[]const u8 {
    const name = std.mem.cutPrefix(u8, sig, "SIG") orelse sig;
    for (known_signals) |k| if (std.mem.eql(u8, k, name)) return k;
    return null;
}

/// Seconds Shepherd waits between the stop signal and SIGKILL; null when the unit sets none and
/// has no stop hook that needs time.
pub fn graceSeconds(u: *const model.Unit, hooks: bool) ?u64 {
    const us = u.timeout_stop_sec orelse return if (hooks) 90 else null;
    if (us == timespan.infinity) return 3600;
    return @max(1, std.math.divCeil(u64, us, std.time.us_per_s) catch unreachable);
}

fn bareSymbol(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0]) or name[0] == '.') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// A symbol as Guile reads it back: bare when plain, in `#{...}#` otherwise.
pub fn writeSymbol(w: *Io.Writer, name: []const u8) Io.Writer.Error!void {
    if (bareSymbol(name)) return w.writeAll(name);
    try w.writeAll("#{");
    for (name) |c| try w.writeByte(if (c == '}' or c == ' ' or c < ' ') '_' else c);
    try w.writeAll("}#");
}

fn writeEscaped(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        ' '...'!', '#'...'[', ']'...'~' => try w.writeByte(c),
        else => try w.writeByte('?'),
    };
}

/// A string literal; characters outside printable ASCII become `?`.
pub fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
}

fn writePrefixed(w: *Io.Writer, prefix: []const u8, value: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    try w.writeAll(prefix);
    try writeEscaped(w, value);
    try w.writeByte('"');
}

fn writeStringList(w: *Io.Writer, words: []const []const u8) Io.Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try writeString(w, word);
    }
}

/// The list of command words: a quoted literal, or a `list` when the primary group of the account
/// is looked up when the service is registered. `extra` words follow the executor arguments.
fn writeCommand(w: *Io.Writer, in: Input, extra: []const []const u8) Io.Writer.Error!void {
    const exec = [_][]const u8{ in.executor_path, "--exec", in.unit.name.full };
    if (in.wrapper) |wr| {
        try w.writeAll("(list ");
        try writeString(w, wr.path);
        try w.writeByte(' ');
        try writePrefixed(w, "--reuid=", wr.user);
        try w.writeByte(' ');
        if (wr.group) |g| {
            try writePrefixed(w, "--regid=", g);
        } else {
            try w.writeAll("(string-append \"--regid=\" (number->string (passwd:gid (getpw ");
            try writeString(w, wr.user);
            try w.writeAll("))))");
        }
        try w.writeAll(" \"--init-groups\" ");
    } else {
        try w.writeAll("'(");
    }
    try writeStringList(w, &exec);
    if (in.user_scope) try w.writeAll(" \"--user\"");
    if (extra.len > 0) {
        try w.writeByte(' ');
        try writeStringList(w, extra);
    }
    try w.writeByte(')');
}

/// The expression that runs the executor to the end and says whether it succeeded.
fn writeRunToEnd(w: *Io.Writer, in: Input, extra: []const []const u8, indent: []const u8) Io.Writer.Error!void {
    try w.writeAll("(eqv? 0 (status:exit-val\n");
    try w.print("{s}                   (spawn-command ", .{indent});
    try writeCommand(w, in, extra);
    try w.writeAll(")))");
}

fn writeStop(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    const hooks = in.stop_on_signal or in.stop_post;
    const grace = graceSeconds(u, hooks);
    const sig: []const u8 = if (u.kill_signal) |s| signalName(s) orelse "TERM" else "TERM";
    if (!in.stop_on_signal and !in.stop_post) {
        if (std.mem.eql(u8, sig, "TERM") and grace == null) return w.writeAll("#:stop (make-kill-destructor)");
        try w.print("#:stop (make-kill-destructor SIG{s}", .{sig});
        if (grace) |g| try w.print(" #:grace-period {d}", .{g});
        return w.writeAll(")");
    }
    try w.writeAll("#:stop (lambda (process . args)\n");
    if (in.stop_on_signal) {
        try w.print("                    (terminate-process (process-id process) SIG{s}", .{sig});
        if (grace) |g| try w.print(" #:grace-period {d}", .{g});
        try w.writeAll(")\n");
    } else {
        try w.print("                    (apply (make-kill-destructor SIG{s}", .{sig});
        if (grace) |g| try w.print(" #:grace-period {d}", .{g});
        try w.writeAll(") process args)\n");
    }
    if (in.stop_post) {
        try w.writeAll("                    (spawn-command ");
        try writeCommand(w, in, &.{ "--phase", "stop-post" });
        try w.writeAll(")\n");
    }
    try w.writeAll("                    #f)");
}

fn writeDescription(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try writeString(w, text);
}

fn writeService(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    const pad = "           ";
    try w.writeAll("(register-services\n (list\n  (service '(");
    try writeSymbol(w, in.service);
    try w.writeAll(")\n");
    try w.print("{s}#:documentation ", .{pad});
    try writeDescription(w, u.description orelse u.name.full);
    try w.writeByte('\n');
    if (in.requirements.len > 0) {
        try w.print("{s}#:requirement '(", .{pad});
        for (in.requirements, 0..) |r, i| {
            if (i > 0) try w.writeByte(' ');
            try writeSymbol(w, r);
        }
        try w.writeAll(")\n");
    }
    switch (in.kind) {
        .daemon => {
            try w.print("{s}#:respawn? {s}\n", .{ pad, if (u.restart == .no) "#f" else "#t" });
            if (u.restart != .no) {
                if (u.restart_sec) |sec| {
                    if (sec != timespan.infinity and sec > 0) {
                        try w.print("{s}#:respawn-delay {d}\n", .{ pad, std.math.divCeil(u64, sec, std.time.us_per_s) catch unreachable });
                    }
                }
            }
            const extra: []const []const u8 = if (in.stop_on_signal) &.{ "--log", "--stop-on-signal" } else &.{"--log"};
            if (in.wrapper != null) {
                // The group of the account is looked up when the service starts, not when it is registered.
                try w.print("{s}#:start (lambda args\n{s}           (apply (make-forkexec-constructor\n{s}                   ", .{ pad, pad, pad });
                try writeCommand(w, in, extra);
                try w.writeAll(")\n");
                try w.print("{s}                  args))\n", .{pad});
            } else {
                try w.print("{s}#:start (make-forkexec-constructor\n{s}         ", .{ pad, pad });
                try writeCommand(w, in, extra);
                try w.writeAll(")\n");
            }
            try w.print("{s}", .{pad});
            try writeStop(w, in);
        },
        .oneshot, .remain => {
            if (in.kind == .oneshot) try w.print("{s}#:one-shot? #t\n", .{pad});
            try w.print("{s}#:start (lambda _\n{s}         ", .{ pad, pad });
            if (in.no_command) {
                try w.writeAll("#t");
            } else {
                try writeRunToEnd(w, in, &.{"--log"}, pad);
            }
            try w.writeByte(')');
            if (in.kind == .remain and in.remain_stop) {
                try w.print("\n{s}#:stop (lambda _\n{s}         (spawn-command ", .{ pad, pad });
                try writeCommand(w, in, &.{ "--phase", "stop" });
                try w.print(")\n{s}         #f)", .{pad});
            }
        },
    }
    try w.writeAll(")))\n");
}

/// The file body: the opening of the block comment that holds the marker, its close, notes as
/// comments, and the registration.
pub fn renderAlloc(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeAll("#!\n!#\n") catch return error.OutOfMemory;
    for (in.notes) |note| w.print(";; {s}\n", .{note}) catch return error.OutOfMemory;
    w.writeAll("(use-modules (shepherd service))\n\n") catch return error.OutOfMemory;
    writeService(w, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;
const name_mod = @import("../../unit/name.zig");

fn testUnit(a: Allocator) !model.Unit {
    return .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
}

test "a daemon is registered with the executor and the default destructor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    u.description = "Foo \"daemon\"";
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .daemon, .service = "foo", .executor_path = "/usr/bin/fake-systemd" });
    try testing.expectEqualStrings(
        \\#!
        \\!#
        \\(use-modules (shepherd service))
        \\
        \\(register-services
        \\ (list
        \\  (service '(foo)
        \\           #:documentation "Foo \"daemon\""
        \\           #:respawn? #f
        \\           #:start (make-forkexec-constructor
        \\                    '("/usr/bin/fake-systemd" "--exec" "foo.service" "--log"))
        \\           #:stop (make-kill-destructor))))
        \\
    , text);
}

test "requirements, respawn, delay, signal and grace period are keywords" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try testUnit(a);
    u.restart = .always;
    u.restart_sec = 2_500_000;
    u.timeout_stop_sec = 20_000_000;
    u.kill_signal = "SIGUSR1";
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .daemon, .service = "foo", .executor_path = "/x", .requirements = &.{ "dbus", "9lives" }, .notes = &.{"a note"} });
    try testing.expect(std.mem.find(u8, text, ";; a note\n") != null);
    try testing.expect(std.mem.find(u8, text, "#:requirement '(dbus #{9lives}#)\n") != null);
    try testing.expect(std.mem.find(u8, text, "#:respawn? #t\n           #:respawn-delay 3\n") != null);
    try testing.expect(std.mem.find(u8, text, "#:stop (make-kill-destructor SIGUSR1 #:grace-period 20)") != null);
}

test "a resident executor is stopped alone, and the stop-post phase follows" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUnit(a);
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .daemon, .service = "foo", .executor_path = "/x", .stop_on_signal = true, .stop_post = true });
    try testing.expect(std.mem.find(u8, text, "\"--log\" \"--stop-on-signal\"") != null);
    try testing.expect(std.mem.find(u8, text, "(terminate-process (process-id process) SIGTERM #:grace-period 90)") != null);
    try testing.expect(std.mem.find(u8, text, "(spawn-command '(\"/x\" \"--exec\" \"foo.service\" \"--phase\" \"stop-post\"))") != null);
    const post_only = try renderAlloc(a, .{ .unit = &u, .kind = .daemon, .service = "foo", .executor_path = "/x", .stop_post = true });
    try testing.expect(std.mem.find(u8, post_only, "(apply (make-kill-destructor SIGTERM #:grace-period 90) process args)") != null);
}

test "an account the executor cannot resolve is switched by setpriv with its group looked up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUnit(a);
    const text = try renderAlloc(a, .{ .unit = &u, .kind = .daemon, .service = "foo", .executor_path = "/x", .wrapper = .{ .path = "/usr/bin/setpriv", .user = "ldap" } });
    try testing.expect(std.mem.find(u8, text, "(list \"/usr/bin/setpriv\" \"--reuid=ldap\" (string-append \"--regid=\" (number->string (passwd:gid (getpw \"ldap\")))) \"--init-groups\" \"/x\" \"--exec\" \"foo.service\" \"--log\")") != null);
    const named = try renderAlloc(a, .{ .unit = &u, .kind = .daemon, .service = "foo", .executor_path = "/x", .wrapper = .{ .path = "/usr/bin/setpriv", .user = "ldap", .group = "staff" } });
    try testing.expect(std.mem.find(u8, named, "\"--reuid=ldap\" \"--regid=staff\" \"--init-groups\"") != null);
}

test "a oneshot waits for the executor and a remaining one stays started" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try testUnit(a);
    const once = try renderAlloc(a, .{ .unit = &u, .kind = .oneshot, .service = "foo", .executor_path = "/x" });
    try testing.expect(std.mem.find(u8, once, "#:one-shot? #t\n") != null);
    try testing.expect(std.mem.find(u8, once, "(eqv? 0 (status:exit-val") != null);
    const remain = try renderAlloc(a, .{ .unit = &u, .kind = .remain, .service = "foo", .executor_path = "/x", .user_scope = true });
    try testing.expect(std.mem.find(u8, remain, "one-shot") == null);
    try testing.expect(std.mem.find(u8, remain, "\"--exec\" \"foo.service\" \"--user\" \"--log\"") != null);
    const empty = try renderAlloc(a, .{ .unit = &u, .kind = .remain, .service = "foo", .executor_path = "/x", .no_command = true });
    try testing.expect(std.mem.find(u8, empty, "#:start (lambda _\n                    #t)") != null);
}

test "symbols and strings are written so that Guile reads them back" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeSymbol(&w, "web-1");
    try w.writeByte(' ');
    try writeSymbol(&w, "1st");
    try w.writeByte(' ');
    try writeSymbol(&w, "a.b");
    try w.writeByte(' ');
    try writeString(&w, "q\"b\\n\x01\xc3");
    try testing.expectEqualStrings("web-1 #{1st}# #{a.b}# \"q\\\"b\\\\n??\"", w.buffered());
}
