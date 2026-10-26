// SPDX-License-Identifier: GPL-3.0-or-later
//! Text of the frontend file of a 66 service from decisions the backend already took. The
//! `[Start]` command is an sh script that runs the unit through the executor, which applies the
//! settings of the unit and feeds the uniform logger; the keys 66 expresses itself (type,
//! dependencies, timeouts, stop signal) are written natively, and a `[Stop]` script carries what
//! has to run when the process ends: the restart policy as the exit status of `finish`, and
//! `ExecStopPost=`.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const shell = @import("../shell.zig");
const s6render = @import("../s6/render.zig");

pub const Identity = union(enum) {
    /// `setpriv`, which resolves the user and its groups through the system libc. Without a
    /// group the primary group of the user is taken at run time; with supplementary groups
    /// those are added to the groups of the user.
    setpriv: struct {
        user: []const u8,
        group: ?[]const u8 = null,
        supplementary: []const []const u8 = &.{},
    },
    /// `execl-runas`, which sets the groups of the account from the system group database.
    runas: []const u8,
};

pub const Input = struct {
    unit: *const model.Unit,
    /// Name of the service in 66, which `finish` asks for the way the process ended.
    service: []const u8,
    /// Services the service depends on; 66 starts them first and stops the service before them.
    depends: []const []const u8 = &.{},
    /// How the start script switches to an account the executor cannot resolve (LDAP, sssd).
    identity: ?Identity = null,
    executor_path: []const u8,
    setpriv_path: []const u8 = "/usr/bin/setpriv",
    runas_path: []const u8 = "/usr/bin/execl-runas",
    /// Absolute path of `66`, which `finish` calls.
    ctl_path: []const u8 = "/usr/bin/66",
    /// Directory of the uniform log of the unit, created for the account the logger runs as.
    log_dir: []const u8,
};

pub const flags_prefix = "# fake-systemd flags:";

const shebang = "#!/bin/sh\n";
/// Exit status of `finish` that tells 66-supervise not to start the service again.
pub const no_restart_status = "125";
/// Signals that end a service cleanly unless `SuccessExitStatus=` says more: HUP, INT, PIPE, TERM.
const default_clean_signals = "1|2|13|15";

/// True when 66 would take `@` followed by `c` for an identifier it replaces in the file.
fn isIdentifier(c: u8) bool {
    return std.mem.findScalar(u8, "IUuGgHSR", c) != null;
}

fn hasIdentifier(text: []const u8) bool {
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, text, i, '@')) |at| {
        if (at + 1 < text.len and isIdentifier(text[at + 1])) return true;
        i = at + 1;
    }
    return false;
}

/// Writes `word` as one shell word. An `@` that 66 would replace is written as `"$at"`, a
/// variable the script sets to `@`, so the word never contains a replaceable identifier.
fn writeWord(w: *Io.Writer, word: []const u8) Io.Writer.Error!void {
    if (!hasIdentifier(word)) return shell.writeWord(w, word, false);
    var rest = word;
    while (std.mem.findScalar(u8, rest, '@')) |at| {
        if (at + 1 >= rest.len or !isIdentifier(rest[at + 1])) {
            try shell.writeWord(w, rest[0 .. at + 1], false);
            rest = rest[at + 1 ..];
            continue;
        }
        if (at > 0) try shell.writeWord(w, rest[0..at], false);
        try w.writeAll("\"$at\"");
        rest = rest[at + 1 ..];
    }
    if (rest.len > 0) try shell.writeWord(w, rest, false);
}

fn wordsNeedAt(words: []const []const u8) bool {
    for (words) |word| if (hasIdentifier(word)) return true;
    return false;
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

/// True when the unit is a 66 oneshot: it runs its commands once.
pub fn isOneshot(u: *const model.Unit) bool {
    return u.service_type == .oneshot;
}

/// True when a oneshot stays active once its commands succeeded.
pub fn holdsAfterExit(u: *const model.Unit) bool {
    return isOneshot(u) and u.remain_after_exit;
}

/// True when the executor stays resident so that `ExecStop=` runs on SIGTERM.
pub fn stopsOnSignal(u: *const model.Unit) bool {
    return !isOneshot(u) and u.exec_stop.len > 0;
}

fn identityOwner(in: Input) ?[]const u8 {
    const ident = in.identity orelse return null;
    return switch (ident) {
        .setpriv => |s| s.user,
        .runas => |user| user,
    };
}

fn writeIdentityPrefix(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const ident = in.identity orelse return;
    switch (ident) {
        .setpriv => |s| {
            try writeWord(w, in.setpriv_path);
            try writeSetprivIdentity(w, s.user, s.group, s.supplementary);
        },
        .runas => |user| {
            try writeWord(w, in.runas_path);
            try w.writeByte(' ');
            try writeWord(w, user);
        },
    }
    try w.writeByte(' ');
}

fn executorWords(gpa: Allocator, in: Input, phase: ?[]const u8, log: bool, stop_on_signal: bool) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    try words.appendSlice(gpa, &.{ in.executor_path, "--exec", in.unit.name.full });
    if (in.unit.scope == .user) try words.append(gpa, "--user");
    if (phase) |p| try words.appendSlice(gpa, &.{ "--phase", p });
    if (log) try words.append(gpa, "--log");
    if (stop_on_signal) try words.append(gpa, "--stop-on-signal");
    return words.items;
}

fn writeWords(w: *Io.Writer, words: []const []const u8) Io.Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try writeWord(w, word);
    }
}

/// Lines that make the log directory writable for the account the executor switches to, which
/// only applies to an account switched by the script.
fn writeLogDirectory(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const owner = identityOwner(in) orelse return;
    if (in.unit.scope != .system) return;
    try w.writeAll("mkdir -p ");
    try writeWord(w, in.log_dir);
    try w.writeAll(" && chown ");
    try writeWord(w, owner);
    try w.writeByte(' ');
    try writeWord(w, in.log_dir);
    try w.writeByte('\n');
}

/// Body of a script that runs `words` as the executor, preceded by what the identity needs.
fn writeExecutorScript(w: *Io.Writer, gpa: Allocator, in: Input, phase: ?[]const u8, stop_on_signal: bool) (Io.Writer.Error || Allocator.Error)!void {
    const words = try executorWords(gpa, in, phase, true, stop_on_signal);
    try w.writeAll(shebang);
    if (wordsNeedAt(words)) try w.writeAll("at=@\n");
    try writeLogDirectory(w, in);
    try w.writeAll("exec ");
    try writeIdentityPrefix(w, in);
    try writeWords(w, words);
    try w.writeByte('\n');
}

fn writeExecute(w: *Io.Writer, script: []const u8) Io.Writer.Error!void {
    try w.writeAll("Execute = (");
    try w.writeAll(script);
    try w.writeAll(")\n");
}

/// Description as the `quotes` syntax of 66 takes it: one line without `"`, and without an `@`
/// that 66 would replace.
fn writeDescription(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '@' and i + 1 < text.len and isIdentifier(text[i + 1])) {
            try w.writeAll("(at)");
        } else if (c == '"') {
            try w.writeByte('\'');
        } else if (c < ' ' or c == 0x7f) {
            try w.writeByte(' ');
        } else try w.writeByte(c);
    }
    try w.writeByte('"');
}

fn descriptionOf(in: Input) []const u8 {
    const text = std.mem.trim(u8, in.unit.description orelse "", " \t");
    return if (text.len > 0) text else in.unit.name.full;
}

fn writeList(w: *Io.Writer, key: []const u8, items: []const []const u8) Io.Writer.Error!void {
    try w.print("{s} = (", .{key});
    for (items) |item| try w.print(" {s}", .{item});
    try w.writeAll(" )\n");
}

/// Milliseconds as 66 takes them in a `Timeout` key.
fn msOf(usec: u64) u64 {
    return std.math.divCeil(u64, usec, std.time.us_per_ms) catch std.math.maxInt(u32);
}

/// True when the service needs a `finish` script: it must not restart after every exit, it
/// waits `RestartSec=` before it does, or it has `ExecStopPost=` commands.
pub fn needsFinish(u: *const model.Unit) bool {
    return !isOneshot(u) and s6render.needsFinish(u);
}

/// True when a oneshot has commands to run when it is stopped.
pub fn needsStop(u: *const model.Unit) bool {
    return isOneshot(u) and (u.exec_stop.len > 0 or u.exec_stop_post.len > 0 or u.runtime_directory.len > 0);
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
        const sig = std.meta.stringToEnum(std.os.linux.SIG, name) orelse continue;
        try w.print("|{d}", .{@backingInt(sig)});
    }
}

fn writeFinishDelay(w: *Io.Writer, u: *const model.Unit, indent: []const u8) Io.Writer.Error!void {
    if (s6render.restartDelay(u)) |secs| try w.print("{s}sleep {d}\n", .{ indent, secs });
}

/// True when the restart policy depends on how the process ended.
fn dependsOnOutcome(u: *const model.Unit) bool {
    return switch (u.restart) {
        .no, .@"on-watchdog", .always => false,
        .@"on-failure", .@"on-success", .@"on-abnormal", .@"on-abort" => true,
    };
}

/// The `finish` script: `ExecStopPost=`, and the restart policy as an exit status 66-supervise
/// reads, from the outcome of the process as `66 runstate` records it when the policy needs it.
fn writeFinish(w: *Io.Writer, gpa: Allocator, in: Input) (Io.Writer.Error || Allocator.Error)!void {
    const u = in.unit;
    try w.writeAll(shebang);
    if (dependsOnOutcome(u)) {
        try w.writeAll("r=$(");
        try writeWord(w, in.ctl_path);
        try w.writeAll(" runstate -nf result ");
        try writeWord(w, in.service);
        try w.writeAll(")\nc=$(");
        try writeWord(w, in.ctl_path);
        try w.writeAll(" runstate -nf code ");
        try writeWord(w, in.service);
        try w.writeAll(")\nclean=\ncase \"$r\" in\nsuccess) clean=1 ;;\nexited) case \"$c\" in ");
        try writeCodes(w, u);
        try w.writeAll(") clean=1 ;; esac ;;\nsignaled) case \"$c\" in ");
        try writeSignals(w, u);
        try w.writeAll(") clean=1 ;; esac ;;\nesac\n");
    }
    if (u.exec_stop_post.len > 0) {
        const words = try executorWords(gpa, in, "stop-post", false, false);
        if (wordsNeedAt(words)) try w.writeAll("at=@\n");
        try writeWords(w, words);
        try w.writeByte('\n');
    }
    switch (u.restart) {
        .no, .@"on-watchdog" => try w.print("exit {s}\n", .{no_restart_status}),
        .always => try writeFinishDelay(w, u, ""),
        .@"on-failure" => {
            try w.print("[ -n \"$clean\" ] && exit {s}\n", .{no_restart_status});
            try writeFinishDelay(w, u, "");
        },
        .@"on-success" => {
            try w.print("[ -n \"$clean\" ] || exit {s}\n", .{no_restart_status});
            try writeFinishDelay(w, u, "");
        },
        .@"on-abnormal", .@"on-abort" => {
            try w.print("[ \"$r\" = signaled ] && [ -z \"$clean\" ] || exit {s}\n", .{no_restart_status});
            try writeFinishDelay(w, u, "");
        },
    }
    if (u.restart != .no and u.restart != .@"on-watchdog") try w.writeAll("exit 0\n");
}

/// What the commands of the backend read back from the file: the unit holds its state after the
/// commands succeeded, restarts after an exit, and which exit codes and signals are a success.
pub const Flags = struct {
    /// A oneshot stays active once its commands succeeded.
    remain: bool = false,
    /// The service starts again after its process ended, whatever the way.
    restarts: bool = false,
    /// `SuccessExitStatus=` exit codes and signal numbers, comma separated.
    ok_codes: []const u8 = "",
    ok_signals: []const u8 = "",
};

pub fn flagsOf(gpa: Allocator, u: *const model.Unit) Allocator.Error!Flags {
    var codes: std.ArrayList(u8) = .empty;
    var signals: std.ArrayList(u8) = .empty;
    for (u.success_exit_status) |entry| {
        if (std.fmt.parseInt(u8, entry, 10)) |code| {
            if (codes.items.len > 0) try codes.append(gpa, ',');
            try codes.print(gpa, "{d}", .{code});
        } else |_| {
            const name = std.mem.cutPrefix(u8, entry, "SIG") orelse continue;
            const sig = std.meta.stringToEnum(std.os.linux.SIG, name) orelse continue;
            if (signals.items.len > 0) try signals.append(gpa, ',');
            try signals.print(gpa, "{d}", .{@backingInt(sig)});
        }
    }
    return .{
        .remain = holdsAfterExit(u),
        .restarts = !isOneshot(u) and u.restart == .always,
        .ok_codes = try codes.toOwnedSlice(gpa),
        .ok_signals = try signals.toOwnedSlice(gpa),
    };
}

fn writeFlags(w: *Io.Writer, f: Flags) Io.Writer.Error!void {
    if (!f.remain and !f.restarts and f.ok_codes.len == 0 and f.ok_signals.len == 0) return;
    try w.writeAll(flags_prefix);
    if (f.remain) try w.writeAll(" remain");
    if (f.restarts) try w.writeAll(" restarts");
    if (f.ok_codes.len > 0) try w.print(" ok-codes={s}", .{f.ok_codes});
    if (f.ok_signals.len > 0) try w.print(" ok-signals={s}", .{f.ok_signals});
    try w.writeByte('\n');
}

pub fn frontend(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    writeFrontend(&aw.writer, gpa, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeFrontend(w: *Io.Writer, gpa: Allocator, in: Input) (Io.Writer.Error || Allocator.Error)!void {
    const u = in.unit;
    const oneshot = isOneshot(u);
    try writeFlags(w, try flagsOf(gpa, u));
    try w.writeAll("[Main]\n");
    try w.print("Type = {s}\n", .{if (oneshot) "oneshot" else "classic"});
    try w.writeAll("Description = ");
    try writeDescription(w, descriptionOf(in));
    try w.writeAll("\nOptions = ( !log )\n");
    if (in.depends.len > 0) try writeList(w, "Depends", in.depends);

    try w.writeAll("\n[Start]\n");
    if (oneshot) {
        if (s6render.startTimeoutMs(u)) |ms| if (ms > 0) try w.print("Timeout = {d}\n", .{ms});
    } else {
        const ms = s6render.killTimeoutMs(u);
        if (ms > 0) try w.print("Timeout = {d}\n", .{ms});
    }
    var script: Io.Writer.Allocating = .init(gpa);
    try writeExecutorScript(&script.writer, gpa, in, null, !oneshot and stopsOnSignal(u));
    try writeExecute(w, script.written());

    if (oneshot) {
        if (!needsStop(u)) return;
        try w.writeAll("\n[Stop]\n");
        if (s6render.stopTimeoutMs(u)) |ms| if (ms > 0) try w.print("Timeout = {d}\n", .{ms});
        var stop: Io.Writer.Allocating = .init(gpa);
        try writeExecutorScript(&stop.writer, gpa, in, "stop", false);
        try writeExecute(w, stop.written());
        return;
    }
    const signal = s6render.downSignal(u);
    const finish = needsFinish(u);
    if (signal == null and !finish) return;
    try w.writeAll("\n[Stop]\n");
    if (signal) |s| try w.print("DownSignal = {s}\n", .{try s6render.signalFileName(gpa, s)});
    if (finish) {
        if (s6render.finishTimeoutMs(u)) |ms| if (ms > 0) try w.print("Timeout = {d}\n", .{ms});
        var script_finish: Io.Writer.Allocating = .init(gpa);
        try writeFinish(&script_finish.writer, gpa, in);
        try writeExecute(w, script_finish.written());
    }
}

const testing = std.testing;

fn expectWord(expected: []const u8, word: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeWord(&w, word);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "an @ that 66 would replace is kept out of the file" {
    try expectWord("plain", "plain");
    try expectWord("foo@bar.service", "foo@bar.service");
    try expectWord("foo\"$at\"Rack1.service", "foo@Rack1.service");
    try expectWord("\"$at\"H", "@H");
    try expectWord("'a b'\"$at\"U", "a b@U");
    try expectWord("a@@x", "a@@x");
    try expectWord("x\"$at\"'Iy z'\"$at\"g", "x@Iy z@g");
    try testing.expect(hasIdentifier("user@Host"));
    try testing.expect(!hasIdentifier("user@host"));
    try testing.expect(!hasIdentifier("mail@"));
}

test "descriptions are one line without quotes or identifiers" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeDescription(&w, "a \"b\"\tc @U d@x @");
    try testing.expectEqualStrings("\"a 'b' c (at)U d@x @\"", w.buffered());
}
