// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of an OpenWrt init script (`#!/bin/sh /etc/rc.common`) from decisions the backend
//! already took.
//!
//! A daemon is a procd instance: `start_service` registers the command with procd, which
//! supervises it and respawns it as the unit's `Restart=` asks. The command is the executor,
//! `fake-systemd --exec <unit> --log`, since procd can send the output of a service to the log
//! daemon but not to a file. `start` returns once the executor has recorded the main process, and
//! `stop` returns when the instance is gone, so that the stop hook `ExecStop=` runs before the
//! script ends, at shutdown as well.
//! A oneshot, and a unit without commands, has no process procd could watch: its script defines
//! `start`, `stop`, `status` and `running` itself and keeps the state in the files the executor
//! writes. A script starts the scripts of the units it requires or wants before its own command.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const shell = @import("../shell.zig");
const sysv = @import("../sysvinit/render.zig");

pub const Mode = sysv.Mode;

pub const Deps = struct {
    /// Services whose scripts `start` runs first and whose failure stops the start.
    requires: []const []const u8 = &.{},
    wants: []const []const u8 = &.{},
    /// Ordering only, which `START` carries.
    after: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
};

/// `procd_set_param respawn <threshold> <timeout> <retry>`: an instance that runs for less than
/// `threshold` seconds counts as a failure, procd waits `timeout` seconds before it starts it
/// again and gives up after `retry` failures in a row, 0 meaning never.
pub const Respawn = struct {
    threshold: u32,
    timeout: u32,
    retry: u32,
};

pub const Input = struct {
    unit: *const model.Unit,
    /// Name of the script in `/etc/init.d`.
    service: []const u8,
    script_dir: []const u8,
    mode: Mode,
    /// A oneshot or a unit without commands that stays active after `start`.
    remain: bool = false,
    deps: Deps = .{},
    start_priority: u8,
    stop_priority: u8,
    respawn: ?Respawn = null,
    /// Seconds procd waits for an instance to end after SIGTERM before it kills it.
    term_timeout: u32,
    /// Files whose change makes `reload` restart the instance.
    watch_files: []const []const u8 = &.{},
    executor_path: []const u8,
    state_dir: []const u8,
    log_dir: []const u8,
    main_pid_file: []const u8,
    exit_file: []const u8,
    /// Comment lines written under the marker.
    notes: []const []const u8 = &.{},
};

pub const shebang = "#!/bin/sh /etc/rc.common\n";

/// Seconds a stop waits beyond `term_timeout` for procd to have killed the instance.
const stop_slack: u32 = 5;

fn oneLine(text: []const u8) []const u8 {
    const end = std.mem.findAny(u8, text, "\r\n") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}

fn writeWord(w: *Io.Writer, word: []const u8) Io.Writer.Error!void {
    return shell.writeWord(w, word, false);
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

/// Starts the scripts of the dependencies; a hard one that fails fails the start.
fn writeDepStarts(w: *Io.Writer, in: Input, indent: []const u8) Io.Writer.Error!void {
    for (in.deps.requires) |dep| {
        try w.print("{s}{s}/", .{ indent, in.script_dir });
        try writeWord(w, dep);
        try w.print(" start || {{\n{s}\techo \"{s}: cannot start\" ", .{ indent, in.unit.name.full });
        try writeWord(w, dep);
        try w.print(" >&2\n{s}\treturn 1\n{s}}}\n", .{ indent, indent });
    }
    for (in.deps.wants) |dep| {
        try w.print("{s}{s}/", .{ indent, in.script_dir });
        try writeWord(w, dep);
        try w.writeAll(" start || :\n");
    }
}

fn writeExecutorCommand(w: *Io.Writer, in: Input, phase: ?[]const u8, tail: []const []const u8) Io.Writer.Error!void {
    try writeWord(w, in.executor_path);
    try w.writeAll(" --exec ");
    try writeWord(w, in.unit.name.full);
    if (phase) |p| try w.print(" --phase {s}", .{p});
    for (tail) |t| try w.print(" {s}", .{t});
}

// ---- daemon ------------------------------------------------------------------------------

/// True when procd has to call `registered` to know whether the service was started, which
/// `ExecStopPost=` and the runtime directories need.
fn needsStopPost(in: Input) bool {
    return sysv.hasStopPost(in.unit);
}

fn writeDaemonHelpers(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    if (!needsStopPost(in) and !sysv.hasReload(in.unit)) return;
    // procd lists the instances of a service it knows, whether they run or ended.
    try w.print("\nregistered() {{\n\t[ -n \"$(ubus call service list '{{\"name\": \"{s}\"}}' | jsonfilter -e '@[\"{s}\"]')\" ]\n}}\n", .{ in.service, in.service });
}

/// True when the executor replaces the pid it records first (its own) with the one of the main
/// process: the daemon that `PIDFile=` names, or the child of an executor that stays resident.
/// Otherwise the main process is the executor itself, after the commands that run before it.
fn replacesOwnPid(u: *const model.Unit) bool {
    return u.service_type == .forking or sysv.stopsOnSignal(u) or u.exec_start_post.len > 0;
}

fn writeDaemonVariables(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("\nmain_pid=");
    try writeWord(w, in.main_pid_file);
    try w.print("\nstart_wait={d}\nmain_replaced={d}\n", .{ sysv.startWait(in.unit), @intFromBool(replacesOwnPid(in.unit)) });
}

/// `start` of `rc.common` returns once procd has started the instance, which is before the
/// executor has run the commands of the unit, so `service_started` waits until the executor has
/// recorded the main process or has ended well, and fails when it ended in failure without a main
/// process to follow or `TimeoutStartSec=` runs out.
fn writeDaemonStarted(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const s = in.service;
    try w.print(
        "\nservice_started() {{\n" ++
            "\t_end=$(($(date +%s) + start_wait))\n" ++
            "\t_i=0\n" ++
            "\twhile [ \"$(date +%s)\" -le \"$_end\" ]; do\n" ++
            "\t\t_list=$(ubus call service list '{{\"name\": \"{s}\"}}')\n" ++
            "\t\t_pid=$(echo \"$_list\" | jsonfilter -e '@[\"{s}\"].instances[*].pid')\n" ++
            "\t\tif [ -s \"$main_pid\" ]; then\n" ++
            "\t\t\t[ \"$main_replaced\" -eq 0 ] && return 0\n" ++
            "\t\t\tif [ -n \"$_pid\" ]; then\n" ++
            "\t\t\t\tread _main _ < \"$main_pid\"\n" ++
            "\t\t\t\t[ \"$_main\" != \"$_pid\" ] && return 0\n" ++
            "\t\t\tfi\n" ++
            "\t\tfi\n" ++
            "\t\tif [ -z \"$_pid\" ]; then\n" ++
            "\t\t\t_code=$(echo \"$_list\" | jsonfilter -e '@[\"{s}\"].instances[*].exit_code')\n" ++
            "\t\t\tcase $_code in 0) return 0 ;; ?*) break ;; esac\n" ++
            "\t\tfi\n" ++
            "\t\t_i=$((_i + 1))\n" ++
            "\t\t[ \"$_i\" -lt 20 ] || sleep 0.05 2>/dev/null || sleep 1\n" ++
            "\tdone\n" ++
            "\techo \"{s} did not come up\" >&2\n" ++
            "\treturn 1\n" ++
            "}}\n",
        .{ s, s, s, in.unit.name.full },
    );
}

/// Unless the service runs, `start_service` removes the pid file a killed executor left, so that
/// `service_started` reads only what the new executor writes.
fn writeDaemonStart(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.print("\nstart_service() {{\n\tprocd_running {s} || rm -f \"$main_pid\"\n", .{in.service});
    try writeDepStarts(w, in, "\t");
    try w.writeAll("\tprocd_open_instance\n\tprocd_set_param command ");
    try writeExecutorCommand(w, in, null, if (sysv.stopsOnSignal(u)) &.{ "--stop-on-signal", "--log" } else &.{"--log"});
    try w.writeByte('\n');
    if (in.respawn) |r| try w.print("\tprocd_set_param respawn {d} {d} {d}\n", .{ r.threshold, r.timeout, r.retry });
    try w.print("\tprocd_set_param term_timeout {d}\n", .{in.term_timeout});
    if (in.watch_files.len > 0) {
        try w.writeAll("\tprocd_set_param file");
        for (in.watch_files) |f| {
            try w.writeByte(' ');
            try writeWord(w, f);
        }
        try w.writeByte('\n');
    }
    try w.writeAll("\tprocd_close_instance\n}\n");
}

/// `stop` of `rc.common` signals the instance and returns at once: the wait runs here, after
/// procd was told to stop it, and `ExecStopPost=` follows once the instance is gone.
fn writeDaemonStop(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    if (needsStopPost(in)) {
        try w.writeAll("\nstop_service() {\n\tregistered && _was_up=1\n}\n");
    }
    try w.print(
        "\nservice_stopped() {{\n" ++
            "\t_n=0\n" ++
            "\twhile procd_running {s} && [ \"$_n\" -lt {d} ]; do\n" ++
            "\t\tsleep 1\n" ++
            "\t\t_n=$((_n + 1))\n" ++
            "\tdone\n",
        .{ in.service, in.term_timeout + stop_slack },
    );
    if (needsStopPost(in)) {
        try w.writeAll("\t[ -n \"$_was_up\" ] && ");
        try writeExecutorCommand(w, in, "stop-post", &.{});
        try w.writeByte('\n');
    }
    try w.writeAll("}\n");
}

fn writeDaemonReload(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("\nreload_service() {\n");
    if (sysv.hasReload(in.unit)) {
        try w.print("\tprocd_running {s} || {{\n\t\techo \"{s} is not running\" >&2\n\t\treturn 7\n\t}}\n\t", .{ in.service, in.unit.name.full });
        try writeExecutorCommand(w, in, "reload", &.{});
        try w.writeByte('\n');
    } else {
        try w.print("\techo \"{s} does not support reload\" >&2\n\treturn 3\n", .{in.unit.name.full});
    }
    try w.writeAll("}\n");
}

// ---- oneshot and units without commands --------------------------------------------------

fn writeStateVariables(w: *Io.Writer, in: Input) Io.Writer.Error!void {
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
}

fn writeOneshotStart(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("\nstart() {\n");
    if (in.remain) try w.writeAll("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) return 0 ;;\n\tesac\n");
    try writeDepStarts(w, in, "\t");
    try w.writeAll("\tmkdir -p \"$state_dir\" \"$log_dir\" || return 1\n\t");
    try writeExecutorCommand(w, in, null, &.{ "--log", "--record-exit" });
    try w.writeAll(" > /dev/null\n\t_rc=$?\n\trm -f \"$main_pid\"\n\treturn \"$_rc\"\n}\n");
}

fn writeStateStart(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll("\nstart() {\n");
    try writeDepStarts(w, in, "\t");
    try w.writeAll("\tmkdir -p \"$state_dir\" || return 1\n");
    if (in.remain) try w.writeAll("\techo 'ok 0' > \"$exit_file\"\n");
    try w.writeAll("}\n");
}

fn writeStateStop(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\nstop() {\n\t_rc=0\n");
    if (in.remain and (u.exec_stop.len > 0 or sysv.hasStopPost(u))) {
        try w.writeAll("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*)\n\t\t");
        try writeExecutorCommand(w, in, "stop", &.{});
        try w.writeAll(" || _rc=$?\n\t\t;;\n\tesac\n");
    }
    try w.writeAll("\trm -f \"$main_pid\" \"$exit_file\"\n\treturn \"$_rc\"\n}\n");
}

fn writeStateStatus(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\nstatus() {\n\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*)\n");
    if (in.remain) {
        try w.print("\t\techo \"{s} is active (exited)\"\n\t\treturn 0\n", .{u.name.full});
    } else try w.print("\t\techo \"{s} has finished\"\n\t\treturn 3\n", .{u.name.full});
    try w.print("\t\t;;\n\tfailed*)\n\t\techo \"{s} failed\"\n\t\treturn 1\n\t\t;;\n\tesac\n", .{u.name.full});
    try w.print("\techo \"{s} is not running\"\n\treturn 3\n}}\n", .{u.name.full});
    try w.writeAll("\nrunning() {\n\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) " ++ (if (in.remain) "return 0" else "return 1") ++ " ;;\n\tesac\n\treturn 1\n}\n");
}

fn writeStateReload(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    try w.writeAll("\nreload() {\n");
    if (sysv.hasReload(u)) {
        try w.print("\tcase $(cat \"$exit_file\" 2>/dev/null) in\n\tok*) ;;\n\t*)\n\t\techo \"{s} is not active\" >&2\n\t\treturn 7\n\t\t;;\n\tesac\n\t", .{u.name.full});
        try writeExecutorCommand(w, in, "reload", &.{});
        try w.writeByte('\n');
    } else {
        try w.print("\techo \"{s} does not support reload\" >&2\n\treturn 3\n", .{u.name.full});
    }
    try w.writeAll("}\n");
}

pub fn script(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeScript(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeScript(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    try w.writeAll(shebang);
    try writeHeader(w, in);
    try w.writeByte('\n');
    if (in.mode == .daemon) try w.writeAll("USE_PROCD=1\n");
    try w.print("START={d:0>2}\nSTOP={d:0>2}\n", .{ in.start_priority, in.stop_priority });
    switch (in.mode) {
        .daemon => {
            try writeDaemonVariables(w, in);
            try writeDaemonHelpers(w, in);
            try writeDaemonStart(w, in);
            try writeDaemonStarted(w, in);
            try writeDaemonStop(w, in);
            try writeDaemonReload(w, in);
        },
        .oneshot, .none => {
            try w.writeAll("EXTRA_COMMANDS=\"status running\"\n");
            try writeStateVariables(w, in);
            if (in.mode == .oneshot) try writeOneshotStart(w, in) else try writeStateStart(w, in);
            try writeStateStop(w, in);
            try writeStateStatus(w, in);
            try writeStateReload(w, in);
        },
    }
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
        .script_dir = "/etc/init.d",
        .mode = .daemon,
        .deps = .{ .requires = &.{"dep\\"} },
        .start_priority = 50,
        .stop_priority = 50,
        .term_timeout = 90,
        .executor_path = "/usr/bin/fake-systemd",
        .state_dir = "/run/fake-systemd",
        .log_dir = "/var/log/fake-systemd/foo.service",
        .main_pid_file = "/run/fake-systemd/foo.service.pid",
        .exit_file = "/run/fake-systemd/foo.service.exit",
    });
    try testing.expect(std.mem.find(u8, text, "echo \"foo.service: cannot start\" 'dep\\' >&2") != null);
    try testing.expect(std.mem.find(u8, text, "cannot start dep\\\"") == null);
}

// ---- the generated `service_started` runs against a fake `ubus` and `jsonfilter` ----------------------

const Fs = @import("../../core/root.zig").Fs;
const execline = @import("../../unit/execline.zig");

const ubus_stub = "#!/bin/sh\ncat \"$(dirname \"$0\")/listing\"\n";
const jsonfilter_stub =
    \\#!/bin/sh
    \\case $2 in *.pid) key=pid ;; *.exit_code) key=exit_code ;; esac
    \\sed -n "s/.*\"$key\": *\([0-9][0-9]*\).*/\1/p"
    \\
;

const Started = struct {
    code: u8,
    stderr: []const u8,
    /// What the pid file held when `service_started` returned.
    main_at_return: []const u8,
};

/// Runs `service_started` of the script of `u` with the pid file holding `initial`, which `late`
/// replaces after half a second, and the listing of procd being `listing`.
fn startedOutcome(a: Allocator, u: *const model.Unit, listing: []const u8, initial: []const u8, late: []const u8) !Started {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try a.dupe(u8, buf[0..try tmp.dir.realPath(testing.io, &buf)]);
    const main_pid = try std.fmt.allocPrint(a, "{s}/main.pid", .{dir});
    const text = try script(a, .{
        .unit = u,
        .service = "foo",
        .script_dir = "/etc/init.d",
        .mode = .daemon,
        .start_priority = 50,
        .stop_priority = 50,
        .term_timeout = 90,
        .executor_path = "/usr/bin/fake-systemd",
        .state_dir = dir,
        .log_dir = dir,
        .main_pid_file = main_pid,
        .exit_file = try std.fmt.allocPrint(a, "{s}/foo.exit", .{dir}),
    });
    try fs.makePath("/bin");
    try fs.writeFileAtomic("/bin/ubus", ubus_stub, 0o755);
    try fs.writeFileAtomic("/bin/jsonfilter", jsonfilter_stub, 0o755);
    try fs.writeFileAtomic("/bin/listing", listing, 0o644);
    try fs.writeFileAtomic("/script", text, 0o755);
    try fs.writeFileAtomic("/main.pid", initial, 0o644);
    const run = try std.fmt.allocPrint(
        a,
        "PATH={s}/bin:$PATH; . {s}/script; ( sleep 0.5; printf '%s\\n' '{s}' > {s} ) & service_started; rc=$?; cat {s}; exit $rc",
        .{ dir, dir, late, main_pid, main_pid },
    );
    const res = try std.process.run(a, testing.io, .{ .argv = &.{ "/bin/sh", "-c", run } });
    return .{ .code = switch (res.term) {
        .exited => |c| c,
        else => 255,
    }, .stderr = res.stderr, .main_at_return = std.mem.trim(u8, res.stdout, " \n") };
}

fn startedUnit(a: Allocator, kind: model.ServiceType, stops: bool) !model.Unit {
    var u: model.Unit = .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
    u.exec_start = try execline.parseAll(a, "/usr/bin/foo");
    u.service_type = kind;
    if (stops) u.exec_stop = try execline.parseAll(a, "/usr/bin/foo stop");
    return u;
}

const running_listing = "{\"foo\": {\"instances\": {\"instance1\": {\"running\": true, \"pid\": 123}}}}";
const ended_listing = "{\"foo\": {\"instances\": {\"instance1\": {\"running\": false, \"exit_code\": 3}}}}";
const finished_listing = "{\"foo\": {\"instances\": {\"instance1\": {\"running\": false, \"exit_code\": 0}}}}";

test "start of a forking unit returns once the executor has replaced its own pid with the daemon's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try startedUnit(a, .forking, false);
    const out = try startedOutcome(a, &u, running_listing, "123 1", "456 1");
    try testing.expectEqual(@as(u8, 0), out.code);
    try testing.expectEqualStrings("456 1", out.main_at_return);
}

test "start of a unit whose executor stays resident waits for the child, one that it replaces does not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const resident = try startedUnit(a, .simple, true);
    const waited = try startedOutcome(a, &resident, running_listing, "123 1", "456 1");
    try testing.expectEqual(@as(u8, 0), waited.code);
    try testing.expectEqualStrings("456 1", waited.main_at_return);
    const direct = try startedUnit(a, .simple, false);
    const at_once = try startedOutcome(a, &direct, running_listing, "123 1", "456 1");
    try testing.expectEqual(@as(u8, 0), at_once.code);
    try testing.expectEqualStrings("123 1", at_once.main_at_return);
}

test "start fails when the executor ended in failure first, and succeeds when it ended well" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try startedUnit(a, .forking, false);
    const failed = try startedOutcome(a, &u, ended_listing, "", "");
    try testing.expectEqual(@as(u8, 1), failed.code);
    try testing.expect(std.mem.find(u8, failed.stderr, "foo.service did not come up") != null);
    const finished = try startedOutcome(a, &u, finished_listing, "", "");
    try testing.expectEqual(@as(u8, 0), finished.code);
}

test "start fails when the executor does not record the main process within TimeoutStartSec" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try startedUnit(a, .forking, false);
    u.timeout_start_sec = 1 * std.time.us_per_s;
    const out = try startedOutcome(a, &u, running_listing, "123 1", "123 1");
    try testing.expectEqual(@as(u8, 1), out.code);
    try testing.expect(std.mem.find(u8, out.stderr, "did not come up") != null);
}

test "start succeeds for a unit that became its main process and failed before the script looked" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try startedUnit(a, .simple, false);
    const out = try startedOutcome(a, &u, ended_listing, "123 1", "123 1");
    try testing.expectEqual(@as(u8, 0), out.code);
}
