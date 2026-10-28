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
const sysv = @import("../sysvinit/render.zig");

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
    /// `command_user`, `user[:group]`: OpenRC switches to it through the system libc and applies the
    /// supplementary groups of the user. Only for a command that is not the executor.
    command_user: ?[]const u8 = null,
    /// An account the executor cannot resolve: the executor stays root and takes the numeric ids
    /// that the script looks up.
    numeric: ?shell.Numeric = null,
    deps: Deps = .{},
    executor_path: []const u8,
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

/// Words of the executor.
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

/// `command` and `command_args` for the program that runs; an executor that is given the numeric
/// identity of its account gets the flags last.
fn writeCommandVars(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const words = commandWords(gpa, in) catch return error.WriteFailed;
    var args: Io.Writer.Allocating = .init(gpa);
    defer args.deinit();
    try w.writeAll("command=");
    try writeWord(w, words[0], true);
    try w.writeByte('\n');
    try writeWords(&args.writer, words[1..], true);
    if (in.command == .executor) {
        if (in.numeric) |n| try shell.writeNumericFlags(&args.writer, n);
    }
    if (args.written().len == 0) return;
    try writeArgsAssignment(w, "command_args", std.mem.trimStart(u8, args.written(), " "));
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

/// A call of the executor from a script function.
fn writeCall(w: *Io.Writer, gpa: Allocator, in: Input, phase: ?[]const u8) Io.Writer.Error!void {
    const words = executorWords(gpa, in, phase, false) catch return error.WriteFailed;
    try writeWords(w, words, false);
    if (in.numeric) |n| try shell.writeNumericFlags(w, n);
}

/// Prepares the log directory of a service whose logger runs as the account of its native command.
fn writeStartPre(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("start_pre() {\n\tmkdir -p ");
    try writeWord(w, in.log_dir, false);
    if (in.command_user) |o| {
        try w.writeAll(" &&\n\t\tcheckpath -q -d -m 0755 -o ");
        try writeWord(w, o, false);
        try w.writeByte(' ');
        try writeWord(w, in.log_dir, false);
    }
    try w.writeAll("\n}\n");
}

/// `start_pre` forgets the files of the last run, so that `start_post` reads only what the new
/// executor writes; `start_post` waits until the executor has recorded the main process or the end
/// of the service, and fails, which stops the service, when the executor dies first or
/// `TimeoutStartSec=` runs out.
fn writeBackgroundWait(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const pidfile = in.pidfile orelse return;
    try w.writeAll("\nstart_pre() {\n\trm -f ");
    try writeWord(w, in.exec_pid_file, false);
    try w.writeByte(' ');
    try writeWord(w, in.exit_file, false);
    try w.print("\n}}\n\nstart_post() {{\n\t_n=0\n\twhile [ \"$_n\" -lt {d} ]; do\n\t\t[ -e ", .{sysv.startWait(in.unit) * 20});
    try writeWord(w, in.exit_file, false);
    try w.writeAll(" ] && return 0\n\t\t_pid=$(cat ");
    try writeWord(w, pidfile, false);
    try w.writeAll(" 2>/dev/null)\n\t\tcase $_pid in ''|*[!0-9]*) ;; *)\n\t\t\tif [ ! -d \"/proc/$_pid\" ]; then\n\t\t\t\t[ -e ");
    try writeWord(w, in.exit_file, false);
    try w.writeAll(" ] && return 0\n\t\t\t\tbreak\n\t\t\tfi\n\t\t\tif [ -s ");
    try writeWord(w, in.exec_pid_file, false);
    try w.writeAll(" ]; then\n");
    if (sysv.replacesOwnPid(in.unit)) {
        try w.writeAll("\t\t\t\tread _main _ < ");
        try writeWord(w, in.exec_pid_file, false);
        try w.writeAll("\n\t\t\t\t[ \"$_main\" != \"$_pid\" ] && return 0\n");
    } else try w.writeAll("\t\t\t\treturn 0\n");
    try w.print("\t\t\tfi\n\t\t\t;;\n\t\tesac\n\t\tsleep 0.05\n\t\t_n=$((_n + 1))\n\tdone\n\teerror \"{s} did not come up\"\n\treturn 1\n}}\n", .{in.unit.name.full});
}

fn needsStartPre(in: Input) bool {
    return switch (in.mode) {
        .oneshot, .none, .forking => false,
        .background => false,
        .supervised => in.logging == .file or (in.command_user != null and in.unit.scope == .system),
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
            if (in.command_user) |spec| {
                try w.writeAll("command_user=");
                try writeWord(w, spec, false);
                try w.writeByte('\n');
            }
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
    if (in.mode == .background) try writeBackgroundWait(w, in);
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

// ---- `start_post` waits for the executor ----------------------------------------------------------

const Fs = @import("../../core/root.zig").Fs;
const name_mod = @import("../../unit/name.zig");

/// Runs `start_post` of a generated background script after `setup`, which sets the files of the
/// executor up in the shell; returns its exit status.
fn startPostCode(a: Allocator, start_timeout_us: ?u64, setup: []const u8) !u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try a.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    var u: model.Unit = .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
    u.timeout_start_sec = start_timeout_us;
    const text = try script(a, .{
        .unit = &u,
        .mode = .background,
        .command = .executor,
        .executor_path = "/usr/bin/fake-systemd",
        .log_dir = try std.fmt.allocPrint(a, "{s}/log", .{dir}),
        .pidfile = try std.fmt.allocPrint(a, "{s}/ssd.pid", .{dir}),
        .exit_file = try std.fmt.allocPrint(a, "{s}/exit", .{dir}),
        .exec_pid_file = try std.fmt.allocPrint(a, "{s}/main", .{dir}),
    });
    const driver = try std.fmt.allocPrint(a, "eerror() {{ echo \"$*\" >&2; }}\n. {s}/foo\nD={s}\n{s}\nstart_post\n", .{ dir, dir, setup });
    try fs.writeFileAtomic("/foo", text, 0o755);
    try fs.writeFileAtomic("/driver", driver, 0o755);
    const res = try std.process.run(a, testing.io, .{ .argv = &.{ "/bin/sh", try std.fmt.allocPrint(a, "{s}/driver", .{dir}) } });
    return switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
}

test "start_post returns once a slow executor recorded a main process of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = "sleep 3 & echo $! > \"$D/ssd.pid\"\n( sleep 0.4; echo \"$$ 1\" > \"$D/main\" ) &";
    try testing.expectEqual(@as(u8, 0), try startPostCode(arena.allocator(), 20 * std.time.us_per_s, setup));
}

test "start_post fails when the executor is gone without an end recorded, and when it does not record in time" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(u8, 1), try startPostCode(arena.allocator(), 20 * std.time.us_per_s, "sh -c 'echo $$ > \"$D/ssd.pid\"'"));
    try testing.expectEqual(@as(u8, 1), try startPostCode(arena.allocator(), 1 * std.time.us_per_s, "sleep 3 & echo $! > \"$D/ssd.pid\""));
}

test "start_post accepts a service that ended and recorded it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const setup = "sh -c 'echo $$ > \"$D/ssd.pid\"'; echo 'failed 3' > \"$D/exit\"";
    try testing.expectEqual(@as(u8, 0), try startPostCode(arena.allocator(), 20 * std.time.us_per_s, setup));
}
