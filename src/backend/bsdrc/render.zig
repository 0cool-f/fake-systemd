// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of a BSD-style rc script (`/etc/rc.d/rc.<name>`, Slackware) from decisions the backend
//! already took. The script takes the verbs `start`, `stop`, `restart`, `reload` and `status`.
//!
//! A service runs under the executor. A daemon is detached by `fake-systemd --exec --daemon`;
//! the executor stays resident, logs, records how the main process ended and turns SIGTERM
//! into the stop. The state is read from three files in the runtime directory: the pid of the
//! executor, the pid of the main process, and the record of how the service ended.
//! A script starts the scripts of the units it requires or wants before its own command.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const shell = @import("../shell.zig");
const sysv = @import("../sysvinit/render.zig");

pub const Mode = sysv.Mode;
pub const Identity = sysv.Identity;

pub const Deps = struct {
    /// Services whose scripts `start` runs first and whose failure stops the start.
    requires: []const []const u8 = &.{},
    wants: []const []const u8 = &.{},
    /// Ordering only: the services whose scripts start before or after this one.
    after: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
};

pub const Input = struct {
    unit: *const model.Unit,
    /// Name of the service; the script is `rc.<service>`.
    service: []const u8,
    /// Directory of the scripts, where the scripts of the dependencies are.
    script_dir: []const u8,
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

const kill_wait: u64 = 5;

fn oneLine(text: []const u8) []const u8 {
    const end = std.mem.findAny(u8, text, "\r\n") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
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

fn writeRelation(w: *Io.Writer, key: []const u8, names: []const []const u8) Io.Writer.Error!void {
    if (names.len == 0) return;
    try w.print("# {s}:", .{key});
    for (names) |n| try w.print(" {s}", .{n});
    try w.writeByte('\n');
}

fn writeHeader(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const description = oneLine(in.unit.description orelse "");
    try w.print("# {s}\n", .{if (description.len > 0) description else in.unit.name.full});
    try writeRelation(w, "Requires", in.deps.requires);
    try writeRelation(w, "Wants", in.deps.wants);
    try writeRelation(w, "After", in.deps.after);
    try writeRelation(w, "Before", in.deps.before);
    for (in.notes) |note| try w.print("# {s}\n", .{note});
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

fn writeVariables(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin\n");
    for ([_]struct { []const u8, []const u8 }{
        .{ "script_dir", in.script_dir },
        .{ "state_dir", in.state_dir },
        .{ "log_dir", in.log_dir },
        .{ "main_pid", in.main_pid_file },
        .{ "exit_file", in.exit_file },
    }) |v| {
        if (std.mem.eql(u8, v[0], "script_dir") and in.deps.requires.len + in.deps.wants.len == 0) continue;
        try w.print("{s}=", .{v[0]});
        try writeWord(w, v[1]);
        try w.writeByte('\n');
    }
    if (in.mode == .daemon) {
        try w.writeAll("daemon_pid=");
        try writeWord(w, in.daemon_pid_file);
        try w.print("\nstop_wait={d}\n", .{sysv.stopWait(in.unit)});
    }
}

/// Runs the script of a dependency with `start`; a script that is not executable, as the
/// script of a service that is not enabled, is run through the shell.
fn writeStartDep(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    if (in.deps.requires.len + in.deps.wants.len == 0) return;
    try w.writeAll(
        "\nstart_dep() {\n" ++
            "\t_s=\"$script_dir/rc.$1\"\n" ++
            "\t[ -e \"$_s\" ] || return 1\n" ++
            "\tif [ -x \"$_s\" ]; then \"$_s\" start; else sh \"$_s\" start; fi\n" ++
            "}\n",
    );
}

fn writeDepStarts(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    for (in.deps.requires) |dep| {
        try w.writeAll("\tstart_dep ");
        try writeWord(w, dep);
        try w.print(" || {{\n\t\techo \"{s}: cannot start\" ", .{in.unit.name.full});
        try writeWord(w, dep);
        try w.writeAll(" >&2\n\t\treturn 1\n\t}\n");
    }
    for (in.deps.wants) |dep| {
        try w.writeAll("\tstart_dep ");
        try writeWord(w, dep);
        try w.writeAll(" || :\n");
    }
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

fn writeDaemonStart(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(gpa, execArgs(gpa, in, null, &.{}) catch return error.WriteFailed) catch return error.WriteFailed;
    args.append(gpa, "--daemon") catch return error.WriteFailed;
    if (sysv.stopsOnSignal(u)) args.append(gpa, "--stop-on-signal") catch return error.WriteFailed;
    args.appendSlice(gpa, &.{ "--log", "--record-exit" }) catch return error.WriteFailed;
    try w.writeAll("\ndo_start() {\n\trunning && return 0\n");
    try writeDepStarts(w, in);
    try w.writeAll("\tmkdir -p \"$state_dir\" \"$log_dir\" || return 1\n\trm -f \"$exit_file\" \"$main_pid\"\n");
    try w.print("\techo \"Starting {s}\"\n\t", .{u.name.full});
    try writeExecutor(w, in, args.items);
    try w.writeAll("\n}\n");
}

/// The script signals the executor itself: SIGTERM, a wait for it to go, and SIGKILL when it
/// stays. The executor stops its main process before it exits.
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
    if (sysv.killsAfterWait(in.unit)) {
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

fn writeDaemonStop(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try writeStopDaemon(w, in);
    try w.writeAll("\ndo_stop() {\n\trc=0\n\tif [ -e \"$daemon_pid\" ]; then\n");
    try w.print("\t\techo \"Stopping {s}\"\n\t\tstop_daemon || rc=$?\n\t\trm -f \"$daemon_pid\"\n\tfi\n", .{u.name.full});
    if (sysv.hasStopPost(u)) {
        try w.writeAll("\tif [ -e \"$exit_file\" ] || [ -e \"$main_pid\" ]; then\n\t\t");
        try writeCall(w, gpa, in, "stop-post", &.{});
        try w.writeAll(" || rc=$?\n\tfi\n");
    }
    try w.writeAll("\trm -f \"$main_pid\" \"$exit_file\"\n\treturn \"$rc\"\n}\n");
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
    if (u.restart != .no) try w.writeAll(" and is not restarted: BSD-style rc does not supervise services");
    try w.writeAll("\"\n\t\treturn 1\n\tfi\n");
    try w.print("\techo \"{s} is not running\"\n\treturn 3\n}}\n", .{u.name.full});
}

fn writeOneshotStart(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\ndo_start() {\n");
    if (in.remain) {
        try w.writeAll("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) return 0 ;;\n\tesac\n");
    }
    try writeDepStarts(w, in);
    try w.writeAll("\tmkdir -p \"$state_dir\" \"$log_dir\" || return 1\n");
    try w.print("\techo \"Starting {s}\"\n\t", .{u.name.full});
    try writeCall(w, gpa, in, null, &.{ "--log", "--record-exit" });
    try w.writeAll(" > /dev/null\n\t_rc=$?\n\trm -f \"$main_pid\"\n\treturn \"$_rc\"\n}\n");
}

fn writeStateStart(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("\ndo_start() {\n");
    try writeDepStarts(w, in);
    try w.writeAll("\tmkdir -p \"$state_dir\" || return 1\n");
    if (in.remain) try w.writeAll("\techo 'ok 0' > \"$exit_file\"\n");
    try w.writeAll("}\n");
}

fn writeStateStop(w: *Io.Writer, gpa: Allocator, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\ndo_stop() {\n\trc=0\n");
    if (in.remain and (u.exec_stop.len > 0 or sysv.hasStopPost(u))) {
        try w.writeAll("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*)\n");
        try w.print("\t\techo \"Stopping {s}\"\n\t\t", .{u.name.full});
        try writeCall(w, gpa, in, "stop", &.{});
        try w.writeAll(" || rc=$?\n\t\t;;\n\tesac\n");
    }
    try w.writeAll("\trm -f \"$main_pid\" \"$exit_file\"\n\treturn \"$rc\"\n}\n");
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
    try w.writeAll("\ncase \"$1\" in\nstart)\n\tdo_start\n\t;;\nstop)\n\tdo_stop\n\t;;\nrestart)\n\tdo_stop\n\tdo_start\n\t;;\n");
    if (sysv.hasReload(in.unit)) {
        try w.writeAll("reload)\n\tdo_reload\n\t;;\n");
    } else {
        try w.print("reload)\n\techo \"{s} does not support reload\" >&2\n\texit 3\n\t;;\n", .{in.unit.name.full});
    }
    try w.writeAll(
        "status)\n\tdo_status\n\t;;\n" ++
            "*)\n\techo \"usage: $0 start|stop|restart|reload|status\" >&2\n\texit 2\n\t;;\nesac\n",
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
    try w.writeByte('\n');
    try writeVariables(w, in);
    try writeStartDep(w, in);
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
    if (sysv.hasReload(in.unit)) try writeReload(w, gpa, in);
    try writeDispatch(w, in);
}

const testing = std.testing;
const name_mod = @import("../../unit/name.zig");

test "the name of a required script is quoted in the message of the start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u: model.Unit = .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
    const text = try script(a, .{
        .unit = &u,
        .service = "foo",
        .script_dir = "/etc/rc.d",
        .mode = .daemon,
        .deps = .{ .requires = &.{"dep\\"} },
        .executor_path = "/usr/bin/fake-systemd",
        .state_dir = "/run/fake-systemd",
        .log_dir = "/var/log/fake-systemd/foo.service",
        .daemon_pid_file = "/run/fake-systemd/foo.service.daemon.pid",
        .main_pid_file = "/run/fake-systemd/foo.service.pid",
        .exit_file = "/run/fake-systemd/foo.service.exit",
    });
    try testing.expect(std.mem.find(u8, text, "echo \"foo.service: cannot start\" 'dep\\' >&2") != null);
    try testing.expect(std.mem.find(u8, text, "cannot start dep\\\"") == null);
}
