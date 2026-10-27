// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of a sysvinit script (LSB 5.0 "Init Script Actions", insserv(8), chkconfig(8),
//! start-stop-daemon(8)) from decisions the backend already took. The script has an LSB header
//! for the ordering `insserv` computes, a `chkconfig` header on Red Hat, and the actions
//! `start`, `stop`, `restart`, `try-restart`, `reload`, `force-reload` and `status`.
//!
//! A service runs under the executor. A daemon is started in the background (by
//! `start-stop-daemon` on Debian, by `fake-systemd --daemon` on Red Hat) and the executor stays
//! resident: it logs, records how the main process ended, and turns SIGTERM into the stop. The
//! state of a service is read from three files in the runtime directory: the pid of the
//! executor, the pid of the main process, and the record of how the service ended.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const timespan = @import("../../unit/timespan.zig");
const shell = @import("../shell.zig");

pub const Variant = enum { debian, redhat };

pub const Mode = enum {
    /// The executor stays resident in the background.
    daemon,
    /// `start` runs the commands to the end; the service then reads inactive, or active with `remain`.
    oneshot,
    /// The unit has no `ExecStart=`.
    none,
};

/// How an account the executor cannot resolve (LDAP, sssd) runs the service: the executor stays
/// root and takes the numeric ids the script looks up.
pub const Identity = struct {
    numeric: ?shell.Numeric = null,
};

pub const Deps = struct {
    /// Facilities and scripts that have to start first, `$remote_fs` among them.
    required: []const []const u8 = &.{},
    should: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
    /// Scripts the service requires, which `enable` enables with it; written as `# Pulls-In:`.
    pulls_in: []const []const u8 = &.{},
};

pub const Input = struct {
    unit: *const model.Unit,
    variant: Variant,
    /// Name of the script.
    service: []const u8,
    mode: Mode,
    /// A oneshot or a unit without commands that stays active after `start`.
    remain: bool = false,
    identity: Identity = .{},
    deps: Deps = .{},
    executor_path: []const u8,
    state_dir: []const u8,
    log_dir: []const u8,
    daemon_pid_file: []const u8,
    main_pid_file: []const u8,
    exit_file: []const u8,
    /// Comment lines written under the marker.
    notes: []const []const u8 = &.{},
};

pub const shebang = "#!/bin/sh\n";

const default_stop_wait: u64 = 90;
const kill_wait: u64 = 5;
/// Longest wait `--retry` takes: the schedule is read as an `int`.
pub const unlimited_wait: u64 = std.math.maxInt(i32);
/// Seconds the executor gets, beyond `TimeoutStopSec=`, to stop its main process before the
/// script kills the executor.
const executor_grace: u64 = 10;

/// Default priorities of `chkconfig`: late in the start sequence, early in the stop sequence.
/// `chkconfig` raises the start priority above that of the scripts a script requires.
const start_priority = 80;
const stop_priority = 20;

pub const lock_dir = "/var/lock/subsys";

/// True when `ExecStop=` has to run whenever the executor is told to stop.
pub fn stopsOnSignal(u: *const model.Unit) bool {
    return u.service_type != .oneshot and u.exec_stop.len > 0;
}

pub fn hasReload(u: *const model.Unit) bool {
    return u.exec_reload.len > 0;
}

pub fn hasStopPost(u: *const model.Unit) bool {
    return u.exec_stop_post.len > 0 or u.runtime_directory.len > 0;
}

/// Seconds a daemon gets to stop: `TimeoutStopSec=` plus the grace of the executor.
pub fn stopWait(u: *const model.Unit) u64 {
    const timeout = u.timeout_stop_sec orelse default_stop_wait * std.time.us_per_s;
    if (timeout == timespan.infinity) return unlimited_wait;
    const secs = std.math.divCeil(u64, timeout, std.time.us_per_s) catch return unlimited_wait;
    return @min(@max(secs, 1) + executor_grace, unlimited_wait);
}

/// True when the executor is killed after the wait: with `TimeoutStopSec=infinity` and
/// `KillMode=none` the service is never killed.
pub fn killsAfterWait(u: *const model.Unit) bool {
    return (u.timeout_stop_sec orelse 0) != timespan.infinity and u.kill_mode != .none;
}

fn oneLine(text: []const u8) []const u8 {
    const end = std.mem.findAny(u8, text, "\r\n") orelse text.len;
    // A trailing backslash would join the next line to a `description:` of `chkconfig`.
    return std.mem.trimEnd(u8, std.mem.trim(u8, text[0..end], " \t"), "\\ \t");
}

fn field(w: *Io.Writer, key: []const u8, values: []const []const u8) Io.Writer.Error!void {
    try w.print("# {s}:", .{key});
    if (values.len == 0) return w.writeByte('\n');
    try w.splatByteAll(' ', 19 - key.len - 1);
    for (values, 0..) |v, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(v);
    }
    try w.writeByte('\n');
}

fn writeHeader(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    const description = oneLine(u.description orelse "");
    const shown = if (description.len > 0) description else u.name.full;
    if (in.variant == .redhat) {
        try w.print("# chkconfig: 2345 {d} {d}\n# description: {s}\n", .{ start_priority, stop_priority, shown });
    }
    try w.writeAll("### BEGIN INIT INFO\n");
    try field(w, "Provides", &.{in.service});
    try field(w, "Required-Start", in.deps.required);
    try field(w, "Required-Stop", in.deps.required);
    if (in.deps.should.len > 0) {
        try field(w, "Should-Start", in.deps.should);
        try field(w, "Should-Stop", in.deps.should);
    }
    if (in.deps.before.len > 0) {
        try field(w, "X-Start-Before", in.deps.before);
        try field(w, "X-Stop-After", in.deps.before);
    }
    try field(w, "Default-Start", &.{ "2", "3", "4", "5" });
    try field(w, "Default-Stop", &.{ "0", "1", "6" });
    try field(w, "Short-Description", &.{shown});
    try w.writeAll("### END INIT INFO\n");
    if (in.deps.pulls_in.len > 0) {
        try w.writeAll("# Pulls-In: ");
        for (in.deps.pulls_in, 0..) |name, i| {
            if (i > 0) try w.writeByte(' ');
            try w.writeAll(name);
        }
        try w.writeByte('\n');
    }
}

fn writeWord(w: *Io.Writer, word: []const u8) Io.Writer.Error!void {
    return shell.writeWord(w, word, false);
}

fn writeWords(w: *Io.Writer, words: []const []const u8) Io.Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try writeWord(w, word);
    }
}

/// The executor with `args`, and the numeric ids of the account after them when the executor cannot
/// resolve it.
fn writeExecutor(w: *Io.Writer, in: Input, args: []const []const u8) Io.Writer.Error!void {
    try writeWord(w, in.executor_path);
    try w.writeByte(' ');
    try writeWords(w, args);
    if (in.identity.numeric) |n| try shell.writeNumericFlags(w, n);
}

fn execArgs(gpa: Allocator, in: Input, phase: ?[]const u8, tail: []const []const u8) Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(gpa, &.{ "--exec", in.unit.name.full });
    if (phase) |p| try args.appendSlice(gpa, &.{ "--phase", p });
    try args.appendSlice(gpa, tail);
    return args.items;
}

/// A call of the executor that runs to the end.
fn writeCall(w: *Io.Writer, gpa: Allocator, in: Input, phase: ?[]const u8, tail: []const []const u8) Io.Writer.Error!void {
    const args = execArgs(gpa, in, phase, tail) catch return error.WriteFailed;
    return writeExecutor(w, in, args);
}

/// True when `start` and `stop` keep a lock file, the convention of Red Hat's `rc` script,
/// which runs a stop link only for a service whose lock file exists.
fn locks(in: Input) bool {
    return in.variant == .redhat and (in.mode == .daemon or in.remain);
}

fn writeVariables(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n");
    for ([_]struct { []const u8, []const u8 }{
        .{ "state_dir", in.state_dir },
        .{ "log_dir", in.log_dir },
        .{ "main_pid", in.main_pid_file },
        .{ "exit_file", in.exit_file },
    }) |v| {
        try w.print("{s}=", .{v[0]});
        try writeWord(w, v[1]);
        try w.writeByte('\n');
    }
    if (in.mode == .daemon) {
        try w.writeAll("daemon_pid=");
        try writeWord(w, in.daemon_pid_file);
        try w.print("\nstop_wait={d}\n", .{stopWait(in.unit)});
    }
    if (locks(in)) try w.print("lock_file={s}/{s}\n", .{ lock_dir, in.service });
}

fn writeDaemonStart(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    var tail: std.ArrayList([]const u8) = .empty;
    if (stopsOnSignal(u)) tail.append(gpa, "--stop-on-signal") catch return error.WriteFailed;
    tail.appendSlice(gpa, &.{ "--log", "--record-exit" }) catch return error.WriteFailed;
    try w.writeAll("\ndo_start() {\n\trunning && return 0\n\tmkdir -p \"$state_dir\" \"$log_dir\" || return 1\n\trm -f \"$exit_file\" \"$main_pid\"\n");
    if (locks(in)) try w.writeAll("\tmkdir -p " ++ lock_dir ++ "\n");
    try w.print("\techo \"Starting {s}\"\n", .{u.name.full});
    switch (in.variant) {
        .debian => {
            const args = execArgs(gpa, in, null, tail.items) catch return error.WriteFailed;
            try w.writeAll("\tstart-stop-daemon --start --quiet --background --make-pidfile --pidfile \"$daemon_pid\" --exec ");
            try writeWord(w, in.executor_path);
            try w.writeAll(" -- ");
            try writeWords(w, args);
            if (in.identity.numeric) |n| try shell.writeNumericFlags(w, n);
            try w.writeByte('\n');
        },
        .redhat => {
            var args: std.ArrayList([]const u8) = .empty;
            args.appendSlice(gpa, execArgs(gpa, in, null, &.{}) catch return error.WriteFailed) catch return error.WriteFailed;
            args.append(gpa, "--daemon") catch return error.WriteFailed;
            args.appendSlice(gpa, tail.items) catch return error.WriteFailed;
            try w.writeByte('\t');
            try writeExecutor(w, in, args.items);
            try w.writeByte('\n');
        },
    }
    try writeStartTail(w, in);
}

/// The lock file of Red Hat, after a start that worked.
fn writeStartTail(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    if (in.variant == .redhat) {
        try w.writeAll("\t_rc=$?\n\t[ \"$_rc\" -eq 0 ] && : > \"$lock_file\"\n\treturn \"$_rc\"\n");
    }
    try w.writeAll("}\n");
}

/// Without `start-stop-daemon` the script signals the executor itself: SIGTERM, a wait for it to
/// go, and SIGKILL when it stays. The executor stops its main process before it exits.
fn writeStopDaemon(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll(
        "\nstop_daemon() {\n" ++
            "\trunning || return 0\n" ++
            "\tkill -TERM \"$_pid\" 2>/dev/null\n" ++
            "\t_n=0\n" ++
            "\twhile running && [ \"$_n\" -lt $((stop_wait * 10)) ]; do\n" ++
            "\t\tsleep 0.1\n" ++
            "\t\t_n=$((_n + 1))\n" ++
            "\tdone\n" ++
            "\trunning || return 0\n",
    );
    if (killsAfterWait(in.unit)) {
        try w.print(
            "\tkill -KILL \"$_pid\" 2>/dev/null\n" ++
                "\t_n=0\n" ++
                "\twhile running && [ \"$_n\" -lt {d} ]; do\n" ++
                "\t\tsleep 0.1\n" ++
                "\t\t_n=$((_n + 1))\n" ++
                "\tdone\n" ++
                "\t! running\n",
            .{kill_wait * 10},
        );
    } else try w.writeAll("\treturn 1\n");
    try w.writeAll("}\n");
}

fn writeStopCommand(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    switch (in.variant) {
        .debian => {
            try w.writeAll("\t\tstart-stop-daemon --stop --quiet --oknodo --retry \"TERM/$stop_wait");
            if (killsAfterWait(in.unit)) try w.print("/KILL/{d}", .{kill_wait});
            try w.writeAll("\" --pidfile \"$daemon_pid\" --name fake-systemd || rc=$?\n");
        },
        .redhat => try w.writeAll("\t\tstop_daemon || rc=$?\n"),
    }
}

fn writeDaemonStop(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    if (in.variant == .redhat) try writeStopDaemon(w, in);
    try w.print("\ndo_stop() {{\n\trc=0\n\techo \"Stopping {s}\"\n\tif [ -e \"$daemon_pid\" ]; then\n", .{u.name.full});
    try writeStopCommand(w, in);
    try w.writeAll("\t\trm -f \"$daemon_pid\"\n\tfi\n");
    if (hasStopPost(u)) {
        try w.writeByte('\t');
        try writeCall(w, gpa, in, "stop-post", &.{});
        try w.writeAll(" || rc=$?\n");
    }
    try w.writeAll("\trm -f \"$main_pid\" \"$exit_file\"\n");
    if (locks(in)) try w.writeAll("\trm -f \"$lock_file\"\n");
    try w.writeAll("\treturn \"$rc\"\n}\n");
}

fn writeDaemonStatus(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.print(
        "\ndo_status() {{\n" ++
            "\tif running; then\n\t\techo \"{s} is running\"\n\t\treturn 0\n\tfi\n" ++
            "\tcase $(cat \"$exit_file\" 2>/dev/null) in\n" ++
            "\tok*)\n\t\techo \"{s} is not running\"\n\t\treturn 3\n\t\t;;\n" ++
            "\tesac\n" ++
            "\tif [ -e \"$daemon_pid\" ] || [ -e \"$exit_file\" ]; then\n" ++
            "\t\techo \"{s} is dead",
        .{ u.name.full, u.name.full, u.name.full },
    );
    if (u.restart != .no) try w.writeAll(" and is not restarted: sysvinit does not supervise services");
    try w.writeAll("\"\n\t\treturn 1\n\tfi\n");
    try w.print("\techo \"{s} is not running\"\n\treturn 3\n}}\n", .{u.name.full});
}

fn writeRunning(w: *Io.Writer) Io.Writer.Error!void {
    try w.writeAll(
        "\nrunning() {\n" ++
            "\t_pid=$(cat \"$daemon_pid\" 2>/dev/null)\n" ++
            "\tcase $_pid in ''|*[!0-9]*) return 1 ;; esac\n" ++
            "\t[ \"$_pid\" -gt 1 ] && [ \"$(cat \"/proc/$_pid/comm\" 2>/dev/null)\" = fake-systemd ]\n" ++
            "}\n",
    );
}

fn writeOneshotStart(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\ndo_start() {\n");
    if (in.remain) {
        try w.writeAll("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) return 0 ;;\n\tesac\n");
    }
    try w.writeAll("\tmkdir -p \"$state_dir\" \"$log_dir\" || return 1\n");
    if (locks(in)) try w.writeAll("\tmkdir -p " ++ lock_dir ++ "\n");
    try w.print("\techo \"Starting {s}\"\n\t", .{u.name.full});
    try writeCall(w, gpa, in, null, &.{ "--log", "--record-exit" });
    try w.writeAll(" > /dev/null\n\t_rc=$?\n\trm -f \"$main_pid\"\n");
    if (locks(in)) try w.writeAll("\t[ \"$_rc\" -eq 0 ] && : > \"$lock_file\"\n");
    try w.writeAll("\treturn \"$_rc\"\n}\n");
}

fn writeStateStart(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("\ndo_start() {\n\tmkdir -p \"$state_dir\" || return 1\n");
    if (in.remain) {
        try w.writeAll("\techo 'ok 0' > \"$exit_file\"\n");
        if (locks(in)) try w.writeAll("\tmkdir -p " ++ lock_dir ++ " && : > \"$lock_file\"\n");
    } else try w.writeAll("\t:\n");
    try w.writeAll("}\n");
}

fn writeStateStop(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\ndo_stop() {\n\trc=0\n");
    if (in.remain and (u.exec_stop.len > 0 or hasStopPost(u))) {
        try w.writeAll("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*)\n");
        try w.print("\t\techo \"Stopping {s}\"\n\t\t", .{u.name.full});
        try writeCall(w, gpa, in, "stop", &.{});
        try w.writeAll(" || rc=$?\n\t\t;;\n\tesac\n");
    }
    try w.writeAll("\trm -f \"$main_pid\" \"$exit_file\"\n");
    if (locks(in)) try w.writeAll("\trm -f \"$lock_file\"\n");
    try w.writeAll("\treturn \"$rc\"\n}\n");
}

fn writeStateStatus(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\ndo_status() {\n\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*)\n");
    if (in.remain) {
        try w.print("\t\techo \"{s} is active (exited)\"\n\t\treturn 0\n", .{u.name.full});
    } else try w.print("\t\techo \"{s} has finished\"\n\t\treturn 3\n", .{u.name.full});
    try w.print("\t\t;;\n\tfailed*)\n\t\techo \"{s} failed\"\n\t\treturn 1\n\t\t;;\n\tesac\n", .{u.name.full});
    try w.print("\techo \"{s} is not running\"\n\treturn 3\n}}\n", .{u.name.full});
}

/// `reload` runs `ExecReload=` through the executor; the service has to be up.
fn writeReload(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\ndo_reload() {\n");
    if (in.mode == .daemon) {
        try w.print("\trunning || {{\n\t\techo \"{s} is not running\" >&2\n\t\treturn 7\n\t}}\n", .{u.name.full});
    } else {
        try w.print("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) ;;\n\t*)\n\t\techo \"{s} is not active\" >&2\n\t\treturn 7\n\t\t;;\n\tesac\n", .{u.name.full});
    }
    try w.writeByte('\t');
    try writeCall(w, gpa, in, "reload", &.{});
    try w.writeAll("\n}\n");
}

fn writeDispatch(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const reload = hasReload(in.unit);
    try w.writeAll("\ncase \"$1\" in\nstart)\n\tdo_start\n\t;;\nstop)\n\tdo_stop\n\t;;\nrestart)\n\tdo_stop\n\tdo_start\n\t;;\n");
    try w.writeAll("try-restart)\n\tif do_status > /dev/null 2>&1; then\n\t\tdo_stop\n\t\tdo_start\n\tfi\n\t;;\n");
    if (reload) {
        try w.writeAll("reload)\n\tdo_reload\n\t;;\nforce-reload)\n\tdo_reload\n\t;;\n");
    } else {
        try w.print("reload)\n\techo \"{s} does not support reload\" >&2\n\texit 3\n\t;;\nforce-reload)\n\tdo_stop\n\tdo_start\n\t;;\n", .{in.unit.name.full});
    }
    try w.writeAll(
        "status)\n\tdo_status\n\t;;\n" ++
            "*)\n\techo \"Usage: $0 {start|stop|restart|try-restart|reload|force-reload|status}\" >&2\n\texit 2\n\t;;\nesac\n",
    );
}

pub fn script(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeScript(&aw.writer, gpa, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeScript(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    try w.writeAll(shebang);
    try writeHeader(w, in);
    for (in.notes) |note| try w.print("# {s}\n", .{note});
    try w.writeByte('\n');
    try writeVariables(w, in);
    switch (in.mode) {
        .daemon => {
            try writeRunning(w);
            try writeDaemonStart(w, gpa, in);
            try writeDaemonStop(w, gpa, in);
            try writeDaemonStatus(w, in);
        },
        .oneshot => {
            try writeOneshotStart(w, gpa, in);
            try writeStateStop(w, gpa, in);
            try writeStateStatus(w, in);
        },
        .none => {
            try writeStateStart(w, in);
            try writeStateStop(w, gpa, in);
            try writeStateStatus(w, in);
        },
    }
    if (hasReload(in.unit)) try writeReload(w, gpa, in);
    try writeDispatch(w, in);
}

const testing = std.testing;

fn testUnit(a: Allocator, text: []const u8) !model.Unit {
    const execline = @import("../../unit/execline.zig");
    var u: model.Unit = .{ .name = try @import("../../unit/name.zig").parse(a, "foo.service"), .scope = .system };
    u.exec_start = try execline.parseAll(a, text);
    return u;
}

test "stop wait adds the grace of the executor and never kills with an infinite timeout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var u = try testUnit(arena.allocator(), "/usr/bin/foo");
    try testing.expectEqual(@as(u64, 100), stopWait(&u));
    try testing.expect(killsAfterWait(&u) or u.timeout_stop_sec == null);
    u.timeout_stop_sec = 1_500_000;
    try testing.expectEqual(@as(u64, 12), stopWait(&u));
    u.timeout_stop_sec = timespan.infinity;
    try testing.expectEqual(unlimited_wait, stopWait(&u));
    try testing.expect(!killsAfterWait(&u));
    u.timeout_stop_sec = 5_000_000;
    u.kill_mode = .none;
    try testing.expect(!killsAfterWait(&u));
}

test "header fields are aligned and empty values stay empty" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try field(&w, "Required-Start", &.{ "$remote_fs", "bar" });
    try field(&w, "Should-Start", &.{});
    try field(&w, "Short-Description", &.{"x"});
    try testing.expectEqualStrings("# Required-Start:    $remote_fs bar\n# Should-Start:\n# Short-Description: x\n", w.buffered());
}

test "a description is cut at its first line" {
    try testing.expectEqualStrings("a b", oneLine("  a b \nsecond"));
    try testing.expectEqualStrings("", oneLine("\nx"));
    // A trailing backslash would join the next line to the `description:` of chkconfig.
    try testing.expectEqualStrings("a b", oneLine("a b \\"));
    try testing.expectEqualStrings("a b", oneLine("a b \\ \\"));
}
