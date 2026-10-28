// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of the scripts of a runit service directory (runsv(8), chpst(8)) from decisions the
//! backend already took: command mode, identity and dependency names. `run` starts the
//! service, `finish` records how it ended and applies `Restart=`, `log/run` feeds the uniform
//! logger and `control/t` stops the service through `ExecStop=` or `KillSignal=`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const model = @import("../../unit/model.zig");
const core = @import("../../core/root.zig");
const timespan = @import("../../unit/timespan.zig");
const shell = @import("../shell.zig");

pub const Command = union(enum) {
    /// Words of `ExecStart=`; `$$` pairs stand for a literal `$`.
    native: []const []const u8,
    /// `fake-systemd --exec <unit>`.
    executor,
};

pub const Identity = union(enum) {
    /// `chpst -u <spec>` with `user[:group[:group...]]`; it applies no supplementary groups of
    /// the user.
    chpst: []const u8,
    /// `setpriv`, which resolves the user and its groups through the system libc. Without a
    /// group the primary group of the user is taken at run time; with supplementary groups
    /// those are added to the groups of the user.
    setpriv: struct {
        user: []const u8,
        group: ?[]const u8 = null,
        supplementary: []const []const u8 = &.{},
    },
};

pub const Input = struct {
    unit: *const model.Unit,
    command: Command,
    /// How `run` switches identity for a native command; null when the unit has no user or the
    /// executor switches it.
    identity: ?Identity = null,
    /// An account the executor cannot resolve: the executor stays root and takes the numeric ids
    /// that the scripts look up, wherever they run it.
    numeric: ?shell.Numeric = null,
    /// Services started with `sv start` before the command, the first group aborting the
    /// script when a start fails.
    hard: []const []const u8 = &.{},
    soft: []const []const u8 = &.{},
    /// `SVDIR` for `sv start`; null leaves the default directory of `sv`.
    svdir: ?[]const u8 = null,
    executor_path: []const u8,
    /// Absolute path of `sleep`, which keeps a oneshot with `RemainAfterExit=` running.
    sleep_path: []const u8 = "/usr/bin/sleep",
    /// Absolute path of `setpriv`, used for `NoNewPrivileges=` in a native command.
    setpriv_path: []const u8 = "/usr/bin/setpriv",
};

/// Name of the file `finish` writes in `supervise/`: `ok|failed <exit code> <signal>`.
pub const exit_status_file = "exit-status";

const shebang = "#!/bin/sh\n";
const hold_seconds = "2147483647";
const default_clean_signals = "1|2|13|15";

pub const writeWord = shell.writeWord;
pub const plainAccount = shell.plainAccount;

fn writeSvStart(w: *Io.Writer, in: Input, name: []const u8) Io.Writer.Error!void {
    if (in.svdir) |dir| {
        try w.writeAll("SVDIR=");
        try writeWord(w, dir, false);
        try w.writeByte(' ');
    }
    try w.writeAll("sv start ");
    try writeWord(w, name, false);
}

/// The executor for `phase`, with the numeric ids of the account last when it cannot resolve it.
fn writeExecutor(w: *Io.Writer, in: Input, phase: ?[]const u8) Io.Writer.Error!void {
    try writeWord(w, in.executor_path, false);
    try w.writeAll(" --exec ");
    try writeWord(w, in.unit.name.full, false);
    if (in.unit.scope == .user) try w.writeAll(" --user");
    if (phase) |p| try w.print(" --phase {s}", .{p});
    if (in.numeric) |n| try shell.writeNumericFlags(w, n);
}

/// True when a oneshot stays `active` after its commands succeeded.
pub fn holdsAfterExit(u: *const model.Unit) bool {
    return u.service_type == .oneshot and u.remain_after_exit;
}

fn writeSetprivIdentity(w: *Io.Writer, user: []const u8, group: ?[]const u8, supplementary: []const []const u8) Io.Writer.Error!void {
    try w.print(" --reuid={s} ", .{user});
    if (group) |g| {
        try w.print("--regid={s}", .{g});
    } else try w.print("--regid=\"$(id -g -- {s})\"", .{user});
    if (supplementary.len == 0) return w.writeAll(" --init-groups");
    try w.print(" --groups \"$(id -G -- {s} | tr ' ' ,)", .{user});
    for (supplementary) |g| try w.print(",{s}", .{g});
    try w.writeByte('"');
}

fn writeCommandWords(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    const chpst_user: ?[]const u8 = if (in.identity) |i| switch (i) {
        .chpst => |spec| spec,
        .setpriv => null,
    } else null;
    const nice: ?i8 = if (in.command == .native) u.nice else null;
    if (chpst_user != null or nice != null) {
        try w.writeAll("chpst");
        if (chpst_user) |spec| {
            try w.writeAll(" -u ");
            try writeWord(w, spec, false);
        }
        if (nice) |n| try w.print(" -n {d}", .{n});
        try w.writeByte(' ');
    }
    const no_new_privs = in.command == .native and (u.no_new_privileges orelse false);
    const setpriv_identity = if (in.identity) |i| switch (i) {
        .setpriv => |s| s,
        .chpst => null,
    } else null;
    if (setpriv_identity != null or no_new_privs) {
        try writeWord(w, in.setpriv_path, false);
        if (setpriv_identity) |s| try writeSetprivIdentity(w, s.user, s.group, s.supplementary);
        if (no_new_privs) try w.writeAll(" --no-new-privs");
        try w.writeByte(' ');
    }
    switch (in.command) {
        .executor => try writeExecutor(w, in, null),
        .native => |words| {
            for (words, 0..) |word, i| {
                if (i > 0) try w.writeByte(' ');
                try writeWord(w, word, true);
            }
        },
    }
}

pub fn run(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeRun(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Longest wait `sv -w` takes on every target: it parses an unsigned long.
pub const unlimited_wait: u64 = std.math.maxInt(u32);

pub const Waits = struct {
    start: ?u64 = null,
    stop: ?u64 = null,
};

fn waitSeconds(usec: ?u64) ?u64 {
    const v = usec orelse return null;
    if (v == timespan.infinity) return unlimited_wait;
    return @min(@max(std.math.divCeil(u64, v, std.time.us_per_s) catch unlimited_wait, 1), unlimited_wait);
}

/// Seconds `sv` waits for the start and the stop of the unit: `TimeoutStartSec=` and
/// `TimeoutStopSec=` rounded up to whole seconds.
pub fn waits(u: *const model.Unit) Waits {
    return .{ .start = waitSeconds(u.timeout_start_sec), .stop = waitSeconds(u.timeout_stop_sec) };
}

pub const waits_prefix = "# sv waits:";

fn writeWaits(w: *Io.Writer, u: *const model.Unit) Io.Writer.Error!void {
    const ws = waits(u);
    if (ws.start == null and ws.stop == null) return;
    try w.writeAll(waits_prefix);
    if (ws.start) |s| try w.print(" start={d}", .{s});
    if (ws.stop) |s| try w.print(" stop={d}", .{s});
    try w.writeByte('\n');
}

fn writeRun(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll(shebang);
    try writeWaits(w, u);
    try w.writeAll("exec 2>&1\n");
    for (in.hard) |dep| {
        try writeSvStart(w, in, dep);
        try w.writeAll(" || exit 1\n");
    }
    for (in.soft) |dep| {
        try writeSvStart(w, in, dep);
        try w.writeByte('\n');
    }
    if (in.command == .native) {
        for (u.environment) |e| {
            try w.print("export {s}=", .{e.name});
            try writeWord(w, e.value, false);
            try w.writeByte('\n');
        }
        if (u.umask) |m| try w.print("umask {o:0>4}\n", .{m});
        if (u.working_directory) |dir| {
            try w.writeAll("cd ");
            try writeWord(w, dir, true);
            try w.writeAll(" || exit 200\n");
        }
    }
    if (holdsAfterExit(u)) {
        try writeCommandWords(w, in);
        try w.writeAll(" || exit $?\n");
        try w.print("exec {s} {s}\n", .{ in.sleep_path, hold_seconds });
    } else {
        try w.writeAll("exec ");
        try writeCommandWords(w, in);
        try w.writeByte('\n');
    }
}

/// True when the service needs a `finish` script: it must not restart after every exit, it
/// waits `RestartSec=` before it does, or it has `ExecStopPost=` commands.
pub fn needsFinish(u: *const model.Unit) bool {
    return u.service_type == .oneshot or u.restart != .always or u.exec_stop_post.len > 0 or restartDelay(u) != null;
}

fn writeCodes(w: *Io.Writer, u: *const model.Unit) Io.Writer.Error!void {
    try w.writeByte('0');
    for (u.success_exit_status) |entry| {
        const code = std.fmt.parseInt(u8, entry, 10) catch continue;
        try w.print("|{d}", .{code});
    }
}

fn writeSignals(w: *Io.Writer, u: *const model.Unit) Io.Writer.Error!void {
    try w.writeAll(default_clean_signals);
    for (u.success_exit_status) |entry| {
        const name = std.mem.cutPrefix(u8, entry, "SIG") orelse continue;
        const sig = std.meta.stringToEnum(linux.SIG, name) orelse continue;
        try w.print("|{d}", .{@backingInt(sig)});
    }
}

/// Seconds `finish` waits before runsv restarts the service, or null for runsv's own pause.
fn restartDelay(u: *const model.Unit) ?u64 {
    const usec = u.restart_sec orelse return null;
    const secs = std.math.divCeil(u64, usec, std.time.us_per_s) catch return null;
    return if (secs > 1 and secs < 24 * 3600) secs else null;
}

fn writeDelayOrNoop(w: *Io.Writer, u: *const model.Unit, indent: []const u8) Io.Writer.Error!void {
    try w.writeAll(indent);
    if (restartDelay(u)) |secs| {
        try w.print("case \"$(cat supervise/stat)\" in *\"want down\"*) ;; *) sleep {d} ;; esac\n", .{secs});
    } else try w.writeAll(":\n");
}

/// The end of a `finish` that keeps the service down. `runsv` reads one control byte per pass and
/// a byte that is still queued when `finish` ends is read after it, so `sv once .` is only sent while
/// the service is wanted up: after a stop `once` would start it again.
pub const once_line = "case \"$(cat supervise/stat)\" in *\"want \"*) ;; *) sv once . ;; esac\n";

pub fn finish(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeFinish(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeFinish(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll(shebang);
    try w.writeAll("clean=\ncase \"$1\" in\n-1) case $(($2 & 127)) in ");
    try writeSignals(w, u);
    try w.writeAll(") clean=1 ;; esac ;;\n");
    try writeCodes(w, u);
    try w.writeAll(") clean=1 ;;\nesac\n");
    try w.writeAll("if [ -n \"$clean\" ]; then verdict=ok; else verdict=failed; fi\n");
    try w.print("printf '%s %s %s\\n' \"$verdict\" \"$1\" \"$2\" > ./supervise/{s}\n", .{exit_status_file});
    if (u.exec_stop_post.len > 0) {
        try writeExecutor(w, in, "stop-post");
        try w.writeByte('\n');
    }
    const restart: model.Restart = if (u.service_type == .oneshot) .no else u.restart;
    switch (restart) {
        .no, .@"on-watchdog" => try w.writeAll(once_line),
        .always => if (restartDelay(u) != null) try writeDelayOrNoop(w, u, ""),
        .@"on-failure" => {
            try w.writeAll("if [ -n \"$clean\" ]; then\n    " ++ once_line ++ "else\n");
            try writeDelayOrNoop(w, u, "    ");
            try w.writeAll("fi\n");
        },
        .@"on-success" => {
            try w.writeAll("if [ -n \"$clean\" ]; then\n");
            try writeDelayOrNoop(w, u, "    ");
            try w.writeAll("else\n    " ++ once_line ++ "fi\n");
        },
        .@"on-abnormal", .@"on-abort" => {
            try w.writeAll("if [ \"$1\" = -1 ] && [ -z \"$clean\" ]; then\n");
            try writeDelayOrNoop(w, u, "    ");
            try w.writeAll("else\n    " ++ once_line ++ "fi\n");
        },
    }
}

/// Name of `sig` for `kill -s`, null when it is not a plain `SIGNAME`.
pub fn killName(sig: []const u8) ?[]const u8 {
    const name = std.mem.cutPrefix(u8, sig, "SIG") orelse sig;
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return null;
    if (std.ascii.isDigit(name[0])) return null;
    return name;
}

fn customSignal(u: *const model.Unit) ?[]const u8 {
    const name = killName(u.kill_signal orelse return null) orelse return null;
    return if (std.mem.eql(u8, name, "TERM")) null else name;
}

/// True when the service has a `control/t`: `ExecStop=` commands, or a stop signal other than
/// SIGTERM.
pub fn needsStopControl(u: *const model.Unit) bool {
    return u.exec_stop.len > 0 or customSignal(u) != null;
}

pub fn stopControl(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeStopControl(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeStopControl(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll(shebang);
    if (in.unit.exec_stop.len > 0) {
        try w.writeAll("MAINPID=$(cat supervise/pid) ");
        try writeExecutor(w, in, "stop-main");
        try w.writeAll("\nexit 1\n");
    } else {
        try w.print("kill -s {s} \"$(cat supervise/pid)\"\n", .{customSignal(in.unit).?});
    }
}

pub fn log(gpa: Allocator, unit_name: []const u8, scope: core.Scope, executor_path: []const u8) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeLog(&aw.writer, unit_name, scope, executor_path) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeLog(w: *Io.Writer, unit_name: []const u8, scope: core.Scope, executor_path: []const u8) Io.Writer.Error!void {
    try w.writeAll(shebang);
    try w.writeAll("exec ");
    try writeWord(w, executor_path, false);
    try w.writeAll(" --log ");
    try writeWord(w, unit_name, false);
    if (scope == .user) try w.writeAll(" --user");
    try w.writeByte('\n');
}

const testing = std.testing;

test "kill names accept plain signal names only" {
    try testing.expectEqualStrings("INT", killName("SIGINT").?);
    try testing.expectEqualStrings("HUP", killName("HUP").?);
    try testing.expectEqualStrings("USR1", killName("SIGUSR1").?);
    try testing.expect(killName("9") == null);
    try testing.expect(killName("sigint") == null);
    try testing.expect(killName("SIG") == null);
}

test "timeouts become whole-second waits and infinity the largest wait sv takes" {
    var u: model.Unit = undefined;
    u.timeout_start_sec = 1_500_000;
    u.timeout_stop_sec = timespan.infinity;
    try testing.expectEqual(@as(?u64, 2), waits(&u).start);
    try testing.expectEqual(@as(?u64, unlimited_wait), waits(&u).stop);
    u.timeout_start_sec = 1;
    u.timeout_stop_sec = null;
    try testing.expectEqual(@as(?u64, 1), waits(&u).start);
    try testing.expectEqual(@as(?u64, null), waits(&u).stop);
}
