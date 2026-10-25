// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of the files of an s6 or s6-rc service from decisions the backend already took: command
//! mode, identity and dependency names. `run` starts a longrun, `up` and `down` start and stop
//! an s6-rc oneshot, `finish` records how a run ended and applies `Restart=`, `log/run` feeds
//! the uniform logger, and small data files carry the stop signal and the timeouts.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const model = @import("../../unit/model.zig");
const core = @import("../../core/root.zig");
const timespan = @import("../../unit/timespan.zig");
const shell = @import("../shell.zig");
const native = @import("native.zig");

pub const Command = union(enum) {
    /// Words of `ExecStart=`; `$$` pairs stand for a literal `$`.
    native: []const []const u8,
    /// `fake-systemd --exec <unit>`.
    executor,
};

pub const Identity = union(enum) {
    /// `s6-setuidgid <user>`: the groups of the user come from the group database, which the
    /// libc of the system enumerates.
    setuidgid: []const u8,
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
    /// How the script switches identity; null when the unit has no user or the executor does it.
    identity: ?Identity = null,
    /// Scan-directory paths of the services started before the command (plain s6); a failed
    /// hard one aborts the script.
    hard: []const []const u8 = &.{},
    soft: []const []const u8 = &.{},
    executor_path: []const u8,
    /// Absolute path of `sleep`, which keeps a oneshot with `RemainAfterExit=` running.
    sleep_path: []const u8 = "/usr/bin/sleep",
    setpriv_path: []const u8 = "/usr/bin/setpriv",
    nice_path: []const u8 = "/usr/bin/nice",
};

/// Name of the file `finish` writes in `supervise/`: `ok|failed <exit code> <signal>`.
pub const exit_status_file = "exit-status";

const shebang = "#!/bin/sh\n";
pub const execline_shebang = "#!/bin/execlineb -P\n";
const hold_seconds = "2147483647";
/// Signals that end a service cleanly unless `SuccessExitStatus=` says more: HUP, INT, PIPE, TERM.
const default_clean_signals = "1|2|13|15";
/// What `s6-supervise` passes `finish` as the exit code of a process that a signal killed.
const signalled = "256";

pub const writeWord = shell.writeWord;
pub const plainAccount = shell.plainAccount;

/// `s6-softlimit` options for the `Limit*=` settings that take a plain number.
pub const limit_flags = [_]struct { systemd: []const u8, flag: []const u8 }{
    .{ .systemd = "LimitNOFILE", .flag = "-o" },
    .{ .systemd = "LimitCORE", .flag = "-c" },
    .{ .systemd = "LimitDATA", .flag = "-d" },
    .{ .systemd = "LimitAS", .flag = "-a" },
    .{ .systemd = "LimitNPROC", .flag = "-p" },
    .{ .systemd = "LimitFSIZE", .flag = "-f" },
    .{ .systemd = "LimitMEMLOCK", .flag = "-l" },
    .{ .systemd = "LimitSTACK", .flag = "-s" },
    .{ .systemd = "LimitRSS", .flag = "-r" },
    .{ .systemd = "LimitCPU", .flag = "-t" },
};

pub fn nativeLimitNames() [limit_flags.len][]const u8 {
    var names: [limit_flags.len][]const u8 = undefined;
    for (limit_flags, &names) |l, *n| n.* = l.systemd;
    return names;
}

fn limitFlag(key: []const u8) ?[]const u8 {
    for (limit_flags) |l| if (std.mem.eql(u8, l.systemd, key)) return l.flag;
    return null;
}

fn writeExecutor(w: *Io.Writer, in: Input, phase: ?[]const u8) Io.Writer.Error!void {
    try writeWord(w, in.executor_path, false);
    try w.writeAll(" --exec ");
    try writeWord(w, in.unit.name.full, false);
    if (in.unit.scope == .user) try w.writeAll(" --user");
    if (phase) |p| try w.print(" --phase {s}", .{p});
}

/// True when the executor stays resident as the supervisor of the service and runs `ExecStop=` when
/// it gets SIGTERM, so that every way the service is brought down runs the stop commands.
pub fn stopsOnSignal(u: *const model.Unit) bool {
    return u.service_type != .oneshot and u.exec_stop.len > 0;
}

/// True when a oneshot stays `active` after its commands succeeded.
pub fn holdsAfterExit(u: *const model.Unit) bool {
    return u.service_type == .oneshot and u.remain_after_exit;
}

fn writeSetprivIdentity(w: *Io.Writer, user: []const u8, group: ?[]const u8, supplementary: []const []const u8) Io.Writer.Error!void {
    try w.print(" --reuid={s} ", .{user});
    if (group) |g| {
        try w.print("--regid={s}", .{g});
    } else try w.print("--regid=\"$(id -g {s})\"", .{user});
    if (supplementary.len == 0) return w.writeAll(" --init-groups");
    try w.print(" --groups \"$(id -G {s} | tr ' ' ,)", .{user});
    for (supplementary) |g| try w.print(",{s}", .{g});
    try w.writeByte('"');
}

/// The flags of `setpriv` that set the identity, as one shell text; `setpriv` is the program.
fn setprivText(gpa: Allocator, in: Input, s: anytype, no_new_privs: bool) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeSetprivWords(&aw.writer, in, s, no_new_privs) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSetprivWords(w: *Io.Writer, in: Input, s: anytype, no_new_privs: bool) Io.Writer.Error!void {
    try writeWord(w, in.setpriv_path, false);
    try writeSetprivIdentity(w, s.user, s.group, s.supplementary);
    if (no_new_privs) try w.writeAll(" --no-new-privs");
}

fn niceOf(in: Input) ?i8 {
    return if (in.command == .native) in.unit.nice else null;
}

fn noNewPrivs(in: Input) bool {
    return in.command == .native and (in.unit.no_new_privileges orelse false);
}

// ---- sh scripts ----------------------------------------------------------------------------

/// The command of a sh script: the programs that prepare the process, then the command words.
fn writeShCommand(w: *Io.Writer, in: Input, words: ?[]const []const u8) Io.Writer.Error!void {
    const u = in.unit;
    if (niceOf(in)) |n| {
        try writeWord(w, in.nice_path, false);
        try w.print(" -n {d} ", .{n});
    }
    if (in.command == .native) {
        var first = true;
        for (u.limits) |l| {
            const flag = limitFlag(l.key) orelse continue;
            if (first) try w.writeAll("s6-softlimit -H");
            first = false;
            try w.print(" {s} ", .{flag});
            try writeWord(w, l.value, false);
        }
        if (!first) try w.writeByte(' ');
    }
    const setpriv_identity = if (in.identity) |i| switch (i) {
        .setpriv => |s| s,
        .setuidgid => null,
    } else null;
    if (in.identity) |i| switch (i) {
        .setuidgid => |user| {
            try w.writeAll("s6-setuidgid ");
            try writeWord(w, user, false);
            try w.writeByte(' ');
        },
        .setpriv => {},
    };
    if (setpriv_identity != null or noNewPrivs(in)) {
        if (setpriv_identity) |s| {
            try writeSetprivWords(w, in, s, noNewPrivs(in));
        } else {
            try writeWord(w, in.setpriv_path, false);
            try w.writeAll(" --no-new-privs");
        }
        try w.writeByte(' ');
    }
    if (words) |ws| {
        for (ws, 0..) |word, i| {
            if (i > 0) try w.writeByte(' ');
            try writeWord(w, word, true);
        }
    } else switch (in.command) {
        .executor => {
            try writeExecutor(w, in, null);
            if (stopsOnSignal(in.unit)) try w.writeAll(" --stop-on-signal");
        },
        .native => |ws| for (ws, 0..) |word, i| {
            if (i > 0) try w.writeByte(' ');
            try writeWord(w, word, true);
        },
    }
}

fn writeFlags(w: *Io.Writer, flags: native.Flags) Io.Writer.Error!void {
    if (!flags.exec_stop and !flags.remain) return;
    try w.writeAll(native.flags_prefix);
    if (flags.exec_stop) try w.writeAll(" exec-stop");
    if (flags.remain) try w.writeAll(" remain");
    try w.writeByte('\n');
}

/// What the commands of the backend need to read back from a generated script: a oneshot that
/// holds after its command has its `ExecStop=` run by the backend at stop.
pub fn flagsOf(u: *const model.Unit) native.Flags {
    return .{
        .exec_stop = u.service_type == .oneshot and u.exec_stop.len > 0,
        .remain = holdsAfterExit(u),
    };
}

pub fn run(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeRun(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Milliseconds for `s6-svwait -t` when a plain s6 script starts a hard dependency.
pub fn hardWaitMs(u: *const model.Unit) u64 {
    const us = u.timeout_start_sec orelse return default_timeout_ms;
    if (us == timespan.infinity) return default_timeout_ms;
    return @max(us / std.time.us_per_ms, 1);
}

/// Milliseconds a script waits for a soft dependency.
pub const soft_wait_ms: u64 = 5000;
pub const default_timeout_ms: u64 = 90_000;

fn writeStart(w: *Io.Writer, path: []const u8, wait_ms: u64, abort: bool) Io.Writer.Error!void {
    try w.writeAll("s6-svc -u ");
    try writeWord(w, path, false);
    try w.writeAll(" 2>/dev/null\n");
    try w.print("s6-svwait -u -t {d} ", .{wait_ms});
    try writeWord(w, path, false);
    try w.writeAll(if (abort) " || exit 1\n" else " || :\n");
}

fn writeRun(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll(shebang);
    try writeFlags(w, flagsOf(u));
    try w.writeAll("exec 2>&1\n");
    for (in.hard) |dep| try writeStart(w, dep, hardWaitMs(u), true);
    for (in.soft) |dep| try writeStart(w, dep, soft_wait_ms, false);
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
        try writeShCommand(w, in, null);
        try w.writeAll(" || exit $?\n");
        try w.print("exec {s} {s}\n", .{ in.sleep_path, hold_seconds });
    } else {
        try w.writeAll("exec ");
        try writeShCommand(w, in, null);
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

/// Seconds `finish` waits before `s6-supervise` restarts the service, or null for its own pause.
pub fn restartDelay(u: *const model.Unit) ?u64 {
    const usec = u.restart_sec orelse return null;
    const secs = std.math.divCeil(u64, usec, std.time.us_per_s) catch return null;
    return if (secs > 1 and secs < 24 * 3600) secs else null;
}

fn writeDelayOrNoop(w: *Io.Writer, u: *const model.Unit, indent: []const u8) Io.Writer.Error!void {
    try w.writeAll(indent);
    if (restartDelay(u)) |secs| {
        try w.print("[ \"$(s6-svstat -o wantedup .)\" = false ] || sleep {d}\n", .{secs});
    } else try w.writeAll(":\n");
}

pub fn finish(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeFinish(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeFinish(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll(shebang);
    try w.print("clean=\ncase \"$1\" in\n{s}) case \"$2\" in ", .{signalled});
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
        .no, .@"on-watchdog" => try w.writeAll("s6-svc -O .\n"),
        .always => if (restartDelay(u) != null) try writeDelayOrNoop(w, u, ""),
        .@"on-failure" => {
            try w.writeAll("if [ -n \"$clean\" ]; then\n    s6-svc -O .\nelse\n");
            try writeDelayOrNoop(w, u, "    ");
            try w.writeAll("fi\n");
        },
        .@"on-success" => {
            try w.writeAll("if [ -n \"$clean\" ]; then\n");
            try writeDelayOrNoop(w, u, "    ");
            try w.writeAll("else\n    s6-svc -O .\nfi\n");
        },
        .@"on-abnormal", .@"on-abort" => {
            try w.print("if [ \"$1\" = {s} ] && [ -z \"$clean\" ]; then\n", .{signalled});
            try writeDelayOrNoop(w, u, "    ");
            try w.writeAll("else\n    s6-svc -O .\nfi\n");
        },
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

// ---- execline scripts of s6-rc oneshots -----------------------------------------------------

/// Writes `word` as one execline word: double quotes when it holds anything but plain
/// characters, with `\\` and `\"` escaped. Execline does no variable expansion in a script run
/// by `execlineb -P`, so `dollars` only turns the `$$` pairs of a systemd command into `$`.
pub fn writeElWord(w: *Io.Writer, word: []const u8, dollars: bool) Io.Writer.Error!void {
    var plain = word.len > 0;
    for (word) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "_-./@%+=:,", c) == null) {
        plain = false;
        break;
    };
    if (plain) return w.writeAll(word);
    try w.writeByte('"');
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        const c = word[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '$' => {
                try w.writeByte('$');
                if (dollars and i + 1 < word.len and word[i + 1] == '$') i += 1;
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeElWords(w: *Io.Writer, words: []const []const u8, dollars: bool) Io.Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try writeElWord(w, word, dollars);
    }
}

fn writeLoggerBlock(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("pipeline -w { ");
    try writeElWord(w, in.executor_path, false);
    try w.writeAll(" --log ");
    try writeElWord(w, in.unit.name.full, false);
    if (in.unit.scope == .user) try w.writeAll(" --user");
    try w.writeAll(" }\nfdmove -c 2 1\n");
}

fn writeElExecutor(w: *Io.Writer, in: Input, phase: ?[]const u8) Io.Writer.Error!void {
    try writeElWord(w, in.executor_path, false);
    try w.writeAll(" --exec ");
    try writeElWord(w, in.unit.name.full, false);
    if (in.unit.scope == .user) try w.writeAll(" --user");
    if (phase) |p| try w.print(" --phase {s}", .{p});
}

/// Execline has no command substitution, so a shell holds the `setpriv` call that needs the
/// primary group of the user; the command words follow as the arguments of that shell.
fn writeElIdentity(w: *Io.Writer, gpa: Allocator, in: Input) (Io.Writer.Error || Allocator.Error)!void {
    const setpriv_identity = if (in.identity) |i| switch (i) {
        .setpriv => |s| s,
        .setuidgid => null,
    } else null;
    if (in.identity) |i| switch (i) {
        .setuidgid => |user| {
            try w.writeAll("s6-setuidgid ");
            try writeElWord(w, user, false);
            try w.writeByte(' ');
        },
        .setpriv => {},
    };
    if (setpriv_identity != null or noNewPrivs(in)) {
        const text = if (setpriv_identity) |s|
            try setprivText(gpa, in, s, noNewPrivs(in))
        else
            try std.fmt.allocPrint(gpa, "{s} --no-new-privs", .{in.setpriv_path});
        const script = try std.fmt.allocPrint(gpa, "exec {s} \"$@\"", .{text});
        try w.writeAll("sh -c ");
        try writeElWord(w, script, false);
        try w.writeAll(" setpriv ");
    }
}

fn writeElChain(w: *Io.Writer, gpa: Allocator, in: Input, words: ?[]const []const u8, phase: ?[]const u8) (Io.Writer.Error || Allocator.Error)!void {
    const u = in.unit;
    try writeLoggerBlock(w, in);
    if (in.command == .native) {
        for (u.environment) |e| {
            try w.print("export {s} ", .{e.name});
            try writeElWord(w, e.value, false);
            try w.writeByte('\n');
        }
        if (u.umask) |m| try w.print("umask {o:0>4}\n", .{m});
        if (u.working_directory) |dir| {
            try w.writeAll("cd ");
            try writeElWord(w, dir, true);
            try w.writeByte('\n');
        }
    }
    if (niceOf(in)) |n| {
        try writeElWord(w, in.nice_path, false);
        try w.print(" -n {d} ", .{n});
    }
    if (in.command == .native) {
        var first = true;
        for (u.limits) |l| {
            const flag = limitFlag(l.key) orelse continue;
            if (first) try w.writeAll("s6-softlimit -H");
            first = false;
            try w.print(" {s} ", .{flag});
            try writeElWord(w, l.value, false);
        }
        if (!first) try w.writeByte(' ');
    }
    try writeElIdentity(w, gpa, in);
    if (words) |ws| {
        try writeElWords(w, ws, true);
    } else switch (in.command) {
        .executor => try writeElExecutor(w, in, phase),
        .native => |ws| try writeElWords(w, ws, true),
    }
    try w.writeByte('\n');
}

/// `up` of a oneshot: the command of the unit, with its output going to the uniform logger.
pub fn up(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeUp(&aw.writer, gpa, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeUp(w: *Io.Writer, gpa: Allocator, in: Input) (Io.Writer.Error || Allocator.Error)!void {
    try w.writeAll(execline_shebang);
    try writeFlags(w, .{ .remain = holdsAfterExit(in.unit) });
    try writeElChain(w, gpa, in, null, null);
}

/// How a oneshot stops: nothing to run, a plain `ExecStop=` command, or the stop phase of the
/// executor for `ExecStop=` and `ExecStopPost=` commands that need it.
pub const Stop = enum { none, native, executor };

pub fn stopKind(u: *const model.Unit, plain_stop: bool) Stop {
    if (plain_stop) return .native;
    if (u.exec_stop.len > 0 or u.exec_stop_post.len > 0) return .executor;
    return .none;
}

/// `down` of a oneshot.
pub fn down(gpa: Allocator, in: Input, stop: Stop, plain_words: []const []const u8) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeDown(&aw.writer, gpa, in, stop, plain_words) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeDown(w: *Io.Writer, gpa: Allocator, in: Input, stop: Stop, plain_words: []const []const u8) (Io.Writer.Error || Allocator.Error)!void {
    try w.writeAll(execline_shebang);
    switch (stop) {
        .none => {},
        .native => try writeElChain(w, gpa, in, plain_words, null),
        .executor => try writeElChain(w, gpa, .{
            .unit = in.unit,
            .command = .executor,
            .executor_path = in.executor_path,
        }, null, "stop"),
    }
}

// ---- data files ----------------------------------------------------------------------------

fn msOf(usec: u64) u64 {
    return std.math.divCeil(u64, usec, std.time.us_per_ms) catch std.math.maxInt(u32);
}

/// What the supervising executor may take beyond two stop timeouts (`ExecStop=` and the
/// termination each get one) before `s6-supervise` kills it.
const stop_supervisor_slack_ms: u64 = 10_000;

/// `timeout-kill`: milliseconds after which `s6-supervise` kills a service that was told to go
/// down, from `TimeoutStopSec=` (systemd's default of 90 s without it); 0 for `infinity`. A
/// supervising executor needs one timeout for `ExecStop=` and one for the termination.
pub fn killTimeoutMs(u: *const model.Unit) u64 {
    const us = u.timeout_stop_sec orelse default_timeout_ms * 1000;
    if (us == timespan.infinity) return 0;
    const ms = @max(msOf(us), 1);
    return if (stopsOnSignal(u)) ms * 2 + stop_supervisor_slack_ms else ms;
}

/// `timeout-finish`: milliseconds `finish` may take, which `ExecStopPost=` and a restart delay
/// stretch beyond the 5 seconds of `s6-supervise`; null leaves the default.
pub fn finishTimeoutMs(u: *const model.Unit) ?u64 {
    const delay = restartDelay(u);
    if (u.exec_stop_post.len == 0 and delay == null) return null;
    const base: u64 = if (u.exec_stop_post.len > 0) killTimeoutMs(u) else 5000;
    if (base == 0) return 0;
    return base + (delay orelse 0) * 1000;
}

/// `down-signal`: the signal `s6-svc -d` sends when `KillSignal=` is not SIGTERM. A supervising
/// executor always gets SIGTERM and sends `KillSignal=` to the process itself.
pub fn downSignal(u: *const model.Unit) ?[]const u8 {
    if (stopsOnSignal(u)) return null;
    const sig = u.kill_signal orelse return null;
    const name = std.mem.cutPrefix(u8, sig, "SIG") orelse sig;
    if (name.len == 0 or std.mem.eql(u8, name, "TERM")) return null;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return null;
    if (std.ascii.isDigit(name[0])) return null;
    return sig;
}

/// Name of the signal as `down-signal` and `s6-svc -s` take it.
pub fn signalFileName(gpa: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, name, "SIG")) return gpa.dupe(u8, name);
    return std.fmt.allocPrint(gpa, "SIG{s}", .{name});
}

/// `timeout-up` of a oneshot, in milliseconds: `TimeoutStartSec=`.
pub fn startTimeoutMs(u: *const model.Unit) ?u64 {
    const us = u.timeout_start_sec orelse return null;
    if (us == timespan.infinity) return 0;
    return @max(msOf(us), 1);
}

/// `timeout-down` of a oneshot, in milliseconds: `TimeoutStopSec=`.
pub fn stopTimeoutMs(u: *const model.Unit) ?u64 {
    const us = u.timeout_stop_sec orelse return null;
    if (us == timespan.infinity) return 0;
    return @max(msOf(us), 1);
}

pub fn numberFile(gpa: Allocator, value: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{d}\n", .{value});
}

pub fn lineFile(gpa: Allocator, value: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\n", .{value});
}

const testing = std.testing;

fn expectWord(expected: []const u8, word: []const u8, dollars: bool) !void {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeElWord(&w, word, dollars);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "words are quoted for execline" {
    try expectWord("plain", "plain", true);
    try expectWord("/usr/bin/foo", "/usr/bin/foo", true);
    try expectWord("--opt=a:b,c", "--opt=a:b,c", true);
    try expectWord("\"\"", "", true);
    try expectWord("\"a b\"", "a b", true);
    try expectWord("\"it's\"", "it's", true);
    try expectWord("\"a\\\"b\"", "a\"b", true);
    try expectWord("\"a\\\\b\"", "a\\b", true);
    try expectWord("\"{\"", "{", true);
    try expectWord("\"#x\"", "#x", true);
    try expectWord("\"a\\nb\"", "a\nb", true);
    try expectWord("\"price$5\"", "price$$5", true);
    try expectWord("\"price$$5\"", "price$$5", false);
    try expectWord("\"$HOME\"", "$HOME", false);
}

test "kill timeouts follow TimeoutStopSec= and default to systemd's 90 seconds" {
    var u: model.Unit = undefined;
    u.service_type = .simple;
    u.exec_stop = &.{};
    u.timeout_stop_sec = null;
    try testing.expectEqual(@as(u64, 90_000), killTimeoutMs(&u));
    u.timeout_stop_sec = 2_500_000;
    try testing.expectEqual(@as(u64, 2500), killTimeoutMs(&u));
    u.timeout_stop_sec = timespan.infinity;
    try testing.expectEqual(@as(u64, 0), killTimeoutMs(&u));
    u.timeout_stop_sec = 1;
    try testing.expectEqual(@as(u64, 1), killTimeoutMs(&u));
    const stop: [1]model.Command = .{.{ .flags = .{}, .words = &.{"/bin/true"} }};
    u.exec_stop = &stop;
    try testing.expect(stopsOnSignal(&u));
    try testing.expectEqual(@as(u64, 10_002), killTimeoutMs(&u));
    u.timeout_stop_sec = null;
    try testing.expectEqual(@as(u64, 190_000), killTimeoutMs(&u));
    u.timeout_stop_sec = timespan.infinity;
    try testing.expectEqual(@as(u64, 0), killTimeoutMs(&u));
    u.service_type = .oneshot;
    try testing.expect(!stopsOnSignal(&u));
}

test "start and stop timeouts of a oneshot and the finish timeout" {
    var u: model.Unit = undefined;
    u.timeout_start_sec = 1_500_000;
    u.timeout_stop_sec = timespan.infinity;
    u.exec_stop_post = &.{};
    u.restart_sec = null;
    try testing.expectEqual(@as(?u64, 1500), startTimeoutMs(&u));
    try testing.expectEqual(@as(?u64, 0), stopTimeoutMs(&u));
    try testing.expectEqual(@as(?u64, null), finishTimeoutMs(&u));
    u.restart_sec = 10 * std.time.us_per_s;
    try testing.expectEqual(@as(?u64, 15_000), finishTimeoutMs(&u));
    u.timeout_start_sec = null;
    try testing.expectEqual(@as(?u64, null), startTimeoutMs(&u));
}

test "the stop signal is a SIG name other than SIGTERM" {
    var u: model.Unit = undefined;
    u.service_type = .simple;
    u.exec_stop = &.{};
    u.kill_signal = "SIGINT";
    try testing.expectEqualStrings("SIGINT", downSignal(&u).?);
    u.kill_signal = "HUP";
    try testing.expectEqualStrings("HUP", downSignal(&u).?);
    u.kill_signal = "SIGTERM";
    try testing.expect(downSignal(&u) == null);
    u.kill_signal = "9";
    try testing.expect(downSignal(&u) == null);
    u.kill_signal = null;
    try testing.expect(downSignal(&u) == null);
    const stop: [1]model.Command = .{.{ .flags = .{}, .words = &.{"/bin/true"} }};
    u.exec_stop = &stop;
    u.kill_signal = "SIGINT";
    try testing.expect(downSignal(&u) == null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("SIGHUP", try signalFileName(arena.allocator(), "SIGHUP"));
    try testing.expectEqualStrings("SIGHUP", try signalFileName(arena.allocator(), "HUP"));
}
