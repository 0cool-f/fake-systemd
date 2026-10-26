// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of an `openrc-run` script (openrc-run(8), supervise-daemon(8), start-stop-daemon(8))
//! from decisions the backend already took: how the service runs, identity, dependency names
//! and logging. The script sets the variables `openrc-run` turns into a `supervise-daemon` or
//! `start-stop-daemon` call, and defines functions only where a unit needs one.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const timespan = @import("../../unit/timespan.zig");
const shell = @import("../shell.zig");
const native = @import("native.zig");

/// How OpenRC runs the service.
pub const Mode = enum {
    /// `supervise-daemon` keeps a foreground process running and respawns it.
    supervised,
    /// `start-stop-daemon` puts the executor in the background under a pid file; the executor logs,
    /// records the exit and stops the main process.
    background,
    /// `start-stop-daemon` starts a command that daemonizes itself.
    forking,
    /// `start()` runs the commands to the end; the service then stays started.
    oneshot,
    /// The unit has no `ExecStart=`; `start()` does nothing.
    none,
};

pub const Command = union(enum) {
    /// Words of `ExecStart=`; `$$` pairs stand for a literal `$`.
    native: []const []const u8,
    /// `fake-systemd --exec <unit>`.
    executor,
};

/// Switching of the account around a program.
pub const Wrapper = union(enum) {
    /// `setpriv`, which resolves the user and its groups through the system libc. Without a
    /// group the primary group of the user is taken at run time; supplementary groups are
    /// added to the groups of the user.
    setpriv: struct {
        user: []const u8,
        group: ?[]const u8 = null,
        supplementary: []const []const u8 = &.{},
    },
    /// `su -s /bin/sh`, which applies the groups of the user and needs no group arguments.
    su: []const u8,
};

pub const Identity = union(enum) {
    /// `command_user`, `user[:group]`: OpenRC switches through the system libc and applies the
    /// supplementary groups of the user.
    command_user: []const u8,
    wrapper: Wrapper,
};

pub const Deps = struct {
    need: []const []const u8 = &.{},
    want: []const []const u8 = &.{},
    use: []const []const u8 = &.{},
    after: []const []const u8 = &.{},
    before: []const []const u8 = &.{},

    fn isEmpty(d: Deps) bool {
        return d.need.len + d.want.len + d.use.len + d.after.len + d.before.len == 0;
    }
};

/// Where the output of a supervised daemon goes.
pub const Logging = enum {
    /// `output_logger` and `error_logger` start `fake-systemd --log` for each stream.
    pipe,
    /// `output_log` and `error_log` append to the `current` file of the unit's log directory;
    /// OpenRC before 0.51 has no logger pipes for `supervise-daemon`.
    file,
};

pub const Input = struct {
    unit: *const model.Unit,
    mode: Mode,
    command: Command,
    /// How a daemon (`supervised`, `background` and `forking` modes) switches account.
    identity: ?Identity = null,
    /// How calls of the executor from script functions switch account; null when the executor
    /// does it or the unit has no account.
    call_wrapper: ?Wrapper = null,
    deps: Deps = .{},
    executor_path: []const u8,
    setpriv_path: []const u8 = "/usr/bin/setpriv",
    logging: Logging = .pipe,
    /// Directory of the uniform log of the unit.
    log_dir: []const u8,
    /// Pid file of `background` mode, and of `forking` mode when the unit names one.
    pidfile: ?[]const u8 = null,
    /// File `--record-exit` writes how the main process ended to.
    exit_file: []const u8 = "",
    /// File the executor writes its own pid to; removed after a oneshot, whose process is gone.
    exec_pid_file: []const u8,
    /// Comment lines written under the marker.
    notes: []const []const u8 = &.{},
};

pub const shebang = "#!/sbin/openrc-run\n";

const default_stop_wait: u64 = 90;
const kill_wait: u64 = 5;
/// Longest wait `retry` takes: `supervise-daemon` and `start-stop-daemon` read it as an `int`.
pub const unlimited_wait: u64 = std.math.maxInt(i32);
/// Respawns a service gets in `respawn_period` seconds, which is systemd's start limit.
const respawn_burst = 5;
const respawn_window = 10;

pub const writeWord = shell.writeWord;
pub const plainAccount = shell.plainAccount;

/// True when `value` can follow `--option` in the unquoted, `eval`-ed command lines of
/// `openrc-run`: no space, quote, glob or expansion character.
pub fn bare(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.findScalar(u8, "_-./@%+=:,", c) == null) return false;
    return true;
}

/// Variables of `openrc-run` and its supervisors, which an exported environment variable must
/// not overwrite.
pub fn reservedName(name: []const u8) bool {
    const exact = [_][]const u8{
        "command",        "command_args",           "command_background",     "command_user",          "directory",
        "pidfile",        "procname",               "name",                   "description",           "retry",
        "supervisor",     "umask",                  "chroot",                 "notify",                "ready",
        "capabilities",   "secbits",                "no_new_privs",           "input_file",            "output_log",
        "error_log",      "output_logger",          "error_logger",           "stopsig",               "opts",
        "extra_commands", "extra_started_commands", "extra_stopped_commands", "required_dirs",         "required_files",
        "start_inactive", "in_background_fake",     "start_stop_daemon_args", "supervise_daemon_args", "command_progress",
    };
    for (exact) |e| if (std.mem.eql(u8, e, name)) return true;
    const prefixes = [_][]const u8{ "command_args_", "respawn_", "healthcheck_", "description_", "rc_", "RC_", "EINFO_", "SSD_" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return std.mem.eql(u8, name, "SVCNAME");
}

/// `NAME` accepted as the name of an exported variable.
pub fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return !reservedName(name);
}

/// True when a oneshot stays `started` in OpenRC although it is `inactive` for systemd.
pub fn transient(u: *const model.Unit) bool {
    return u.service_type == .oneshot and !u.remain_after_exit;
}

fn writeDoubleQuoted(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| {
        if (std.mem.findScalar(u8, "\"\\$`", c) != null) try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

fn writeWords(w: *Io.Writer, words: []const []const u8, dollars: bool) Io.Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try writeWord(w, word, dollars);
    }
}

/// `command_args` holds shell words that `openrc-run` evaluates once more, so each word is
/// quoted for that and the whole value again for the assignment.
fn writeArgsAssignment(w: *Io.Writer, name: []const u8, text: []const u8) Io.Writer.Error!void {
    try w.print("{s}=", .{name});
    try writeDoubleQuoted(w, text);
    try w.writeByte('\n');
}

/// The flags of `setpriv` that set the account, each behind a space.
fn setprivFlags(w: *Io.Writer, s: anytype) Io.Writer.Error!void {
    try w.print(" --reuid={s} ", .{s.user});
    if (s.group) |g| {
        try w.print("--regid={s}", .{g});
    } else try w.print("--regid=\"$(id -g {s})\"", .{s.user});
    if (s.supplementary.len == 0) return w.writeAll(" --init-groups");
    try w.print(" --groups \"$(id -G {s} | tr ' ' ,)", .{s.user});
    for (s.supplementary) |g| try w.print(",{s}", .{g});
    try w.writeByte('"');
}

fn executorWords(gpa: Allocator, in: Input, phase: ?[]const u8, stop_on_signal: bool) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    try words.appendSlice(gpa, &.{ in.executor_path, "--exec", in.unit.name.full });
    if (in.unit.scope == .user) try words.append(gpa, "--user");
    if (phase) |p| try words.appendSlice(gpa, &.{ "--phase", p });
    if (stop_on_signal) try words.append(gpa, "--stop-on-signal");
    return words.items;
}

/// True when the executor stays resident as the parent of the main process and runs `ExecStop=`
/// when it gets SIGTERM, so every way the service is brought down runs the stop commands.
pub fn stopsOnSignal(u: *const model.Unit) bool {
    return u.service_type != .oneshot and u.exec_stop.len > 0;
}

fn commandWords(gpa: Allocator, in: Input) Allocator.Error![]const []const u8 {
    return switch (in.command) {
        .native => |words| words,
        .executor => blk: {
            var words: std.ArrayList([]const u8) = .empty;
            try words.appendSlice(gpa, try executorWords(gpa, in, null, stopsOnSignal(in.unit)));
            // Without a supervisor of its own the executor logs and records the exit.
            if (in.mode == .background) try words.appendSlice(gpa, &.{ "--log", "--record-exit" });
            break :blk words.items;
        },
    };
}

/// `command` and `command_args` for the program that runs, with a `setpriv` wrapper in front
/// when the identity needs one.
fn writeCommandVars(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const words = commandWords(gpa, in) catch return error.WriteFailed;
    var args: Io.Writer.Allocating = .init(gpa);
    defer args.deinit();
    const wrapper: ?Wrapper = if (in.identity) |ident| switch (ident) {
        .wrapper => |wrap| wrap,
        .command_user => null,
    } else null;
    if (wrapper != null and wrapper.? == .setpriv) {
        try w.writeAll("command=");
        try writeWord(w, in.setpriv_path, false);
        try w.writeByte('\n');
        try setprivFlags(&args.writer, wrapper.?.setpriv);
        try args.writer.writeAll(" -- ");
        try writeWords(&args.writer, words, true);
        return writeArgsAssignment(w, "command_args", std.mem.trimStart(u8, args.written(), " "));
    }
    try w.writeAll("command=");
    try writeWord(w, words[0], true);
    try w.writeByte('\n');
    if (words.len == 1) return;
    try writeWords(&args.writer, words[1..], true);
    try writeArgsAssignment(w, "command_args", args.written());
}

fn writeSeconds(w: *Io.Writer, usec: u64) Io.Writer.Error!void {
    if (usec == timespan.infinity) return w.print("{d}", .{unlimited_wait});
    const secs = std.math.divCeil(u64, usec, std.time.us_per_s) catch unlimited_wait;
    try w.print("{d}", .{@min(@max(secs, 1), unlimited_wait)});
}

/// Name of `sig` for the `retry` schedule, null when it is not a plain `SIGNAME`.
pub fn killName(sig: []const u8) ?[]const u8 {
    const name = std.mem.cutPrefix(u8, sig, "SIG") orelse sig;
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return null;
    if (std.ascii.isDigit(name[0])) return null;
    return name;
}

/// Seconds a recording executor gets, beyond `TimeoutStopSec=`, to kill its main process before
/// start-stop-daemon kills the executor.
const executor_grace: u64 = 10;

/// `retry` schedule: the stop signal, the wait that `TimeoutStopSec=` gives it, then SIGKILL.
/// With `TimeoutStopSec=infinity` the service is never killed. A recording executor takes
/// SIGTERM as the request to stop and sends `KillSignal=` to its main process itself, so it gets
/// SIGTERM and a grace period for that.
fn writeRetry(w: *Io.Writer, u: *const model.Unit, recording: bool) Io.Writer.Error!void {
    const sig = if (recording) "TERM" else killName(u.kill_signal orelse "TERM") orelse "TERM";
    try w.print("retry={s}/", .{sig});
    const timeout = u.timeout_stop_sec orelse default_stop_wait * std.time.us_per_s;
    if (recording and timeout != timespan.infinity) {
        try writeSeconds(w, timeout + executor_grace * std.time.us_per_s);
    } else try writeSeconds(w, timeout);
    if (timeout != timespan.infinity and u.kill_mode != .none) try w.print("/KILL/{d}", .{kill_wait});
    try w.writeByte('\n');
}

/// Seconds `respawn_delay` waits: `RestartSec=` rounded up, one second without it. OpenRC
/// before 0.5x takes whole seconds only and rejects 0.
pub fn respawnDelay(u: *const model.Unit) u64 {
    const usec = u.restart_sec orelse return 1;
    const secs = std.math.divCeil(u64, usec, std.time.us_per_s) catch return 1;
    return @min(@max(secs, 1), 24 * 3600);
}

fn writeRespawn(w: *Io.Writer, u: *const model.Unit) Io.Writer.Error!void {
    const delay = respawnDelay(u);
    try w.print("respawn_delay={d}\n", .{delay});
    if (delay * respawn_burst > respawn_window) {
        try w.writeAll("respawn_max=0\n");
    } else try w.print("respawn_max={d}\nrespawn_period={d}\n", .{ respawn_burst, respawn_window });
}

fn limitFlag(key: []const u8) ?[]const u8 {
    for (limit_flags) |l| if (std.mem.eql(u8, l.systemd, key)) return l.flag;
    return null;
}

/// `ulimit` options for the `Limit*=` settings whose unit is the same in systemd and in the
/// shell: file descriptors, processes and CPU seconds.
pub const limit_flags = [_]struct { systemd: []const u8, flag: []const u8 }{
    .{ .systemd = "LimitNOFILE", .flag = "n" },
    .{ .systemd = "LimitNPROC", .flag = "u" },
    .{ .systemd = "LimitCPU", .flag = "t" },
};

pub fn nativeLimitNames() [limit_flags.len][]const u8 {
    var names: [limit_flags.len][]const u8 = undefined;
    for (limit_flags, &names) |l, *n| n.* = l.systemd;
    return names;
}

fn writeUlimitValue(w: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    try w.writeAll(if (std.mem.eql(u8, value, "infinity")) "unlimited" else value);
}

/// `rc_ulimit` pairs for one limit: `-n 4096`, or `-Sn soft -Hn hard`.
fn writeUlimit(w: *Io.Writer, flag: []const u8, value: []const u8) Io.Writer.Error!void {
    if (std.mem.findScalar(u8, value, ':')) |colon| {
        try w.print("-S{s} ", .{flag});
        try writeUlimitValue(w, value[0..colon]);
        try w.print(" -H{s} ", .{flag});
        try writeUlimitValue(w, value[colon + 1 ..]);
    } else {
        try w.print("-{s} ", .{flag});
        try writeUlimitValue(w, value);
    }
}

fn writeLimits(w: *Io.Writer, u: *const model.Unit) Io.Writer.Error!void {
    var first = true;
    for (u.limits) |l| {
        const flag = limitFlag(l.key) orelse continue;
        try w.writeAll(if (first) "rc_ulimit=\"" else " ");
        first = false;
        try writeUlimit(w, flag, l.value);
    }
    if (!first) try w.writeAll("\"\n");
}

fn writeLogging(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    var value: Io.Writer.Allocating = .init(gpa);
    defer value.deinit();
    switch (in.logging) {
        .pipe => {
            try writeWord(&value.writer, in.executor_path, false);
            try value.writer.writeAll(" --log ");
            try writeWord(&value.writer, in.unit.name.full, false);
            if (in.unit.scope == .user) try value.writer.writeAll(" --user");
            for ([_][]const u8{ "output_logger", "error_logger" }) |key| {
                try w.print("{s}=", .{key});
                try writeWord(w, value.written(), false);
                try w.writeByte('\n');
            }
        },
        .file => {
            try value.writer.print("{s}/current", .{in.log_dir});
            for ([_][]const u8{ "output_log", "error_log" }) |key| {
                try w.print("{s}=", .{key});
                try writeWord(w, value.written(), false);
                try w.writeByte('\n');
            }
        },
    }
}

fn writeDepLine(w: *Io.Writer, key: []const u8, names: []const []const u8) Io.Writer.Error!void {
    if (names.len == 0) return;
    try w.print("\t{s}", .{key});
    for (names) |n| {
        try w.writeByte(' ');
        try writeWord(w, n, false);
    }
    try w.writeByte('\n');
}

fn writeDepend(w: *Io.Writer, deps: Deps) Io.Writer.Error!void {
    if (deps.isEmpty()) return;
    try w.writeAll("\ndepend() {\n");
    try writeDepLine(w, "need", deps.need);
    try writeDepLine(w, "want", deps.want);
    try writeDepLine(w, "use", deps.use);
    try writeDepLine(w, "after", deps.after);
    try writeDepLine(w, "before", deps.before);
    try w.writeAll("}\n");
}

/// A call of the executor from a script function, wrapped in the account switch when needed.
fn writeCall(w: *Io.Writer, gpa: Allocator, in: Input, phase: ?[]const u8) Io.Writer.Error!void {
    const words = executorWords(gpa, in, phase, false) catch return error.WriteFailed;
    const wrap = in.call_wrapper orelse return writeWords(w, words, false);
    switch (wrap) {
        .setpriv => |s| {
            try writeWord(w, in.setpriv_path, false);
            try setprivFlags(w, s);
            try w.writeByte(' ');
            try writeWords(w, words, false);
        },
        .su => |user| {
            var inner: Io.Writer.Allocating = .init(gpa);
            defer inner.deinit();
            try inner.writer.writeAll("exec ");
            try writeWords(&inner.writer, words, false);
            try w.writeAll("su -s /bin/sh -c ");
            try writeWord(w, inner.written(), false);
            try w.writeByte(' ');
            try writeWord(w, user, false);
        },
    }
}

/// Account the service runs as, for the files its executor and logger write.
fn identityOwner(in: Input) ?[]const u8 {
    const ident = in.identity orelse return null;
    return switch (ident) {
        .command_user => |spec| spec,
        .wrapper => |wrap| switch (wrap) {
            .setpriv => |s| s.user,
            .su => |user| user,
        },
    };
}

/// Prepares what root has to create for a service whose executor or logger runs as an account:
/// the log directory, and in `background` mode the files the executor rewrites in place.
fn writeStartPre(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const owner = identityOwner(in);
    try w.writeAll("start_pre() {\n\tmkdir -p ");
    try writeWord(w, in.log_dir, false);
    if (in.mode == .background and owner != null) {
        try w.writeByte(' ');
        try writeWord(w, std.fs.path.dirname(in.exec_pid_file) orelse "/run", false);
    }
    if (owner) |o| {
        try w.writeAll(" &&\n\t\tcheckpath -q -d -m 0755 -o ");
        try writeWord(w, o, false);
        try w.writeByte(' ');
        try writeWord(w, in.log_dir, false);
        if (in.mode == .background) {
            for ([_][]const u8{ in.exit_file, in.exec_pid_file }) |file| {
                try w.writeAll(" &&\n\t\tcheckpath -q -f -m 0644 -o ");
                try writeWord(w, o, false);
                try w.writeByte(' ');
                try writeWord(w, file, false);
            }
        }
    }
    try w.writeAll("\n}\n");
}

fn needsStartPre(in: Input) bool {
    return switch (in.mode) {
        .oneshot, .none, .forking => false,
        .background => in.identity != null and in.unit.scope == .system,
        .supervised => in.logging == .file or (if (in.identity) |ident| ident == .command_user and in.unit.scope == .system else false),
    };
}

/// True when the script has a `reload` function.
pub fn hasReload(u: *const model.Unit) bool {
    return u.exec_reload.len > 0;
}

fn hasStopPost(u: *const model.Unit) bool {
    return u.exec_stop_post.len > 0 or u.runtime_directory.len > 0;
}

fn mainPidAssignment(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    if (in.command == .executor) return;
    switch (in.mode) {
        .supervised => try w.writeAll("MAINPID=$(service_get_value child_pid) "),
        .background, .forking => if (in.pidfile) |p| {
            try w.writeAll("MAINPID=$(cat ");
            try writeWord(w, p, false);
            try w.writeAll(" 2>/dev/null) ");
        },
        .oneshot, .none => {},
    }
}

fn writeOneshotStart(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    try w.writeAll("\nstart() {\n\tebegin \"Starting ${RC_SVCNAME}\"\n\texec 4>&1\n\t_rc=$( { { ");
    try writeCall(w, gpa, in, null);
    try w.writeAll(" 2>&1; echo $? >&3; } | ");
    try writeWord(w, in.executor_path, false);
    try w.writeAll(" --log ");
    try writeWord(w, in.unit.name.full, false);
    if (in.unit.scope == .user) try w.writeAll(" --user");
    try w.writeAll(" >&4; } 3>&1 )\n\texec 4>&-\n\trm -f ");
    try writeWord(w, in.exec_pid_file, false);
    try w.writeAll("\n\teend \"${_rc:-1}\" \"Failed to start ${RC_SVCNAME}\"\n}\n");
}

pub fn script(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeScript(&aw.writer, gpa, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeScript(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll(shebang);
    if (transient(u) or in.mode == .background) {
        try w.writeAll(native.flags_prefix);
        if (transient(u)) try w.writeAll(" transient");
        if (in.mode == .background) try w.writeAll(" record-exit");
        try w.writeByte('\n');
    }
    for (in.notes) |note| try w.print("# {s}\n", .{note});
    if (u.description) |d| {
        try w.writeAll("description=");
        try writeWord(w, d, false);
        try w.writeByte('\n');
    }
    if (hasReload(u)) try w.writeAll("extra_started_commands=\"reload\"\n");

    const is_native = in.command == .native;
    if (is_native and in.mode != .oneshot and in.mode != .none) {
        for (u.environment) |e| {
            try w.print("export {s}=", .{e.name});
            try writeWord(w, e.value, false);
            try w.writeByte('\n');
        }
        try writeLimits(w, u);
    }

    switch (in.mode) {
        .supervised, .background, .forking => {
            if (in.mode == .supervised) try w.writeAll("supervisor=supervise-daemon\n");
            try writeCommandVars(w, gpa, in);
            if (in.identity) |ident| switch (ident) {
                .command_user => |spec| {
                    try w.writeAll("command_user=");
                    try writeWord(w, spec, false);
                    try w.writeByte('\n');
                },
                .wrapper => {},
            };
            if (in.mode == .background) try w.writeAll("command_background=yes\n");
            if (in.pidfile) |p| {
                try w.writeAll("pidfile=");
                try writeWord(w, p, false);
                try w.writeByte('\n');
            }
            if (is_native) {
                if (u.working_directory) |dir| {
                    try w.writeAll("directory=");
                    try writeWord(w, dir, true);
                    try w.writeByte('\n');
                }
                if (u.umask) |m| try w.print("umask={o:0>4}\n", .{m});
                if (u.no_new_privileges orelse false) try w.writeAll("no_new_privs=yes\n");
                if (u.nice) |n| try w.print("start_stop_daemon_args=\"--nicelevel {d}\"\n", .{n});
            }
            try writeRetry(w, u, in.mode == .background);
            if (in.mode == .supervised) try writeRespawn(w, u);
            if (in.mode == .supervised) try writeLogging(w, gpa, in);
        },
        .oneshot, .none => {},
    }

    try writeDepend(w, in.deps);

    if (needsStartPre(in)) {
        try w.writeByte('\n');
        try writeStartPre(w, in);
    }
    switch (in.mode) {
        .oneshot => {
            try writeOneshotStart(w, gpa, in);
            if (!transient(u) and (u.exec_stop.len > 0 or hasStopPost(u))) {
                try w.writeAll("\nstop() {\n\tebegin \"Stopping ${RC_SVCNAME}\"\n\t");
                try writeCall(w, gpa, in, "stop");
                try w.writeAll("\n\teend $?\n}\n");
            }
        },
        .none => try w.writeAll("\nstart() {\n\t:\n}\n"),
        else => if (hasStopPost(u)) {
            try w.writeAll("\nstop_post() {\n\t");
            try writeCall(w, gpa, in, "stop-post");
            try w.writeAll("\n}\n");
        },
    }
    if (hasReload(u)) {
        try w.writeAll("\nreload() {\n\tebegin \"Reloading ${RC_SVCNAME}\"\n\t");
        try mainPidAssignment(w, in);
        try writeCall(w, gpa, in, "reload");
        try w.writeAll("\n\teend $?\n}\n");
    }
}

const testing = std.testing;

test "kill names accept plain signal names only" {
    try testing.expectEqualStrings("INT", killName("SIGINT").?);
    try testing.expectEqualStrings("HUP", killName("HUP").?);
    try testing.expect(killName("9") == null);
    try testing.expect(killName("sigint") == null);
    try testing.expect(killName("SIG") == null);
}

test "bare values and reserved names" {
    try testing.expect(bare("/usr/bin/foo"));
    try testing.expect(bare("svc:grp"));
    try testing.expect(!bare("/opt/my app"));
    try testing.expect(!bare("a'b"));
    try testing.expect(!bare("*"));
    try testing.expect(!bare(""));
    try testing.expect(validEnvName("FOO_BAR"));
    try testing.expect(!validEnvName("command"));
    try testing.expect(!validEnvName("respawn_delay"));
    try testing.expect(!validEnvName("RC_SVCNAME"));
    try testing.expect(!validEnvName("1X"));
    try testing.expect(!validEnvName("A-B"));
}
