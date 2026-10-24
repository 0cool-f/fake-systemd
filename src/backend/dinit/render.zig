//! Text of a dinit serviXXe description (dinit-service(5)) from decisions already taken by the
//! backend: service kind, command mode, identity, dependency names and log file.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const model = @import("../../unit/model.zig");
const timespan = @import("../../unit/timespan.zig");

pub const Kind = enum { process, bgprocess, scripted };

pub const Command = union(enum) {
    /// Words of `ExecStart=`; `$$` pairs are kept, which dinit reads as a literal `$`.
    native: []const []const u8,
    /// `fake-systemd --exec <unit>`.
    executor,
};

pub const Stop = union(enum) {
    none,
    native: []const []const u8,
    executor,
};

pub const Deps = struct {
    depends_on: []const []const u8 = &.{},
    waits_for: []const []const u8 = &.{},
    after: []const []const u8 = &.{},
    before: []const []const u8 = &.{},
};

pub const Input = struct {
    unit: *const model.Unit,
    kind: Kind,
    command: Command,
    stop: Stop = .none,
    executor_path: []const u8,
    /// Identity dinit switches to; null when the unit has none or the executor does it.
    run_as: ?[]const u8 = null,
    deps: Deps = .{},
    log_file: ?[]const u8 = null,
    /// Comment lines that explain a setting dinit cannot honor exactly.
    notes: []const []const u8 = &.{},
};

pub const log_permissions = "640";

const env_path = "/usr/bin/env";

pub const rlimit_keys = [_]struct { systemd: []const u8, dinit: []const u8 }{
    .{ .systemd = "LimitNOFILE", .dinit = "rlimit-nofile" },
    .{ .systemd = "LimitCORE", .dinit = "rlimit-core" },
    .{ .systemd = "LimitDATA", .dinit = "rlimit-data" },
    .{ .systemd = "LimitAS", .dinit = "rlimit-addrspace" },
};

pub fn nativeLimitNames() [rlimit_keys.len][]const u8 {
    var names: [rlimit_keys.len][]const u8 = undefined;
    for (rlimit_keys, &names) |k, *n| n.* = k.systemd;
    return names;
}

/// Writes one word of a command line. `literal` escapes `$` for values that are not subject to
/// expansion in systemd; otherwise `$$` pairs pass through unchanged.
pub fn writeWord(w: *Io.Writer, word: []const u8, literal: bool) Io.Writer.Error!void {
    return writeWordParts(w, &.{word}, literal);
}

/// One word made of `parts` joined without separator.
pub fn writeWordParts(w: *Io.Writer, parts: []const []const u8, literal: bool) Io.Writer.Error!void {
    var empty = true;
    var special = false;
    for (parts) |p| {
        if (p.len > 0) empty = false;
        if (std.mem.findAny(u8, p, " \t\"#") != null) special = true;
    }
    const quote = empty or special;
    if (quote) try w.writeByte('"');
    for (parts) |part| for (part) |c| switch (c) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '$' => try w.writeAll(if (literal) "$$" else "$"),
        else => try w.writeByte(c),
    };
    if (quote) try w.writeByte('"');
}

fn writeWords(w: *Io.Writer, words: []const []const u8) Io.Writer.Error!void {
    for (words, 0..) |word, i| {
        if (i > 0) try w.writeByte(' ');
        try writeWord(w, word, false);
    }
}

/// Seconds with at most three decimals, rounded up so a non-zero span never becomes 0.
pub fn writeSeconds(w: *Io.Writer, usec: u64) Io.Writer.Error!void {
    if (usec == timespan.infinity) return w.writeByte('0');
    const ms = std.math.divCeil(u64, usec, 1000) catch unreachable;
    const whole = ms / 1000;
    const frac = ms % 1000;
    if (frac == 0) return w.print("{d}", .{whole});
    var buf: [3]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>3}", .{frac}) catch unreachable;
    const digits = std.mem.trimEnd(u8, &buf, "0");
    try w.print("{d}.{s}", .{ whole, digits });
}

fn writeLimit(w: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    var it = std.mem.splitScalar(u8, value, ':');
    var first = true;
    while (it.next()) |part| {
        if (!first) try w.writeByte(':');
        first = false;
        try w.writeAll(if (std.mem.eql(u8, part, "infinity")) "-" else part);
    }
}

fn signalName(sig: []const u8) ?[]const u8 {
    const name = std.mem.cutPrefix(u8, sig, "SIG") orelse sig;
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c)) return null;
    if (std.ascii.isDigit(name[0])) return null;
    return name;
}

fn restartValue(r: model.Restart) []const u8 {
    return switch (r) {
        .no => "false",
        .always, .@"on-success" => "true",
        .@"on-failure", .@"on-abnormal", .@"on-watchdog", .@"on-abort" => "on-failure",
    };
}

fn writeCommandLine(w: *Io.Writer, key: []const u8, in: Input, cmd: []const []const u8, env: bool) Io.Writer.Error!void {
    try w.print("{s} = ", .{key});
    if (env) {
        try w.writeAll(env_path);
        for (in.unit.environment) |e| {
            try w.writeByte(' ');
            try writeWordParts(w, &.{ e.name, "=", e.value }, true);
        }
        try w.writeByte(' ');
    }
    try writeWords(w, cmd);
    try w.writeByte('\n');
}

fn writeExecutorLine(w: *Io.Writer, key: []const u8, in: Input, phase: ?[]const u8) Io.Writer.Error!void {
    try w.print("{s} = {s} --exec ", .{ key, in.executor_path });
    try writeWord(w, in.unit.name.full, true);
    if (in.unit.scope == .user) try w.writeAll(" --user");
    if (phase) |p| try w.print(" --phase {s}", .{p});
    try w.writeByte('\n');
}

fn writeDeps(w: *Io.Writer, key: []const u8, names: []const []const u8) Io.Writer.Error!void {
    for (names) |n| try w.print("{s} = {s}\n", .{ key, n });
}

pub fn render(w: *Io.Writer, in: Input) Io.Writer.Error!void {
    const u = in.unit;
    for (in.notes) |note| try w.print("# {s}\n", .{note});
    try w.print("type = {s}\n", .{@tagName(in.kind)});
    switch (in.command) {
        .native => |words| try writeCommandLine(w, "command", in, words, u.environment.len > 0),
        .executor => try writeExecutorLine(w, "command", in, null),
    }
    switch (in.stop) {
        .none => {},
        .native => |words| try writeCommandLine(w, "stop-command", in, words, false),
        .executor => try writeExecutorLine(w, "stop-command", in, "stop"),
    }
    if (in.run_as) |user| {
        try w.writeAll("run-as = ");
        try writeWord(w, user, true);
        try w.writeAll("\nload-options = export-passwd-vars\n");
    }
    if (u.working_directory) |dir| {
        if (in.command == .native) {
            try w.writeAll("working-dir = ");
            try writeWord(w, dir, true);
            try w.writeByte('\n');
        }
    }

    const restarts = in.kind != .scripted and u.restart != .no;
    try w.print("restart = {s}\n", .{if (in.kind == .scripted) "false" else restartValue(u.restart)});
    if (restarts) {
        try w.writeAll("smooth-recovery = true\n");
        if (u.restart_sec) |sec| {
            try w.writeAll("restart-delay = ");
            try writeSeconds(w, sec);
            try w.writeByte('\n');
        }
    }
    if (u.timeout_start_sec) |sec| {
        try w.writeAll("start-timeout = ");
        try writeSeconds(w, sec);
        try w.writeByte('\n');
    }
    if (u.timeout_stop_sec) |sec| {
        try w.writeAll("stop-timeout = ");
        try writeSeconds(w, sec);
        try w.writeByte('\n');
    }
    if (in.kind != .scripted) {
        if (u.kill_signal) |sig| {
            if (signalName(sig)) |name| {
                if (!std.mem.eql(u8, name, "TERM")) try w.print("term-signal = {s}\n", .{name});
            }
        }
    }
    const no_new_privs = u.no_new_privileges orelse false;
    const process_only = u.kill_mode == .process and in.kind != .scripted;
    if (no_new_privs or process_only) {
        try w.writeAll("options:");
        if (no_new_privs) try w.writeAll(" no-new-privs");
        if (process_only) try w.writeAll(" signal-process-only");
        try w.writeByte('\n');
    }
    if (u.nice) |n| try w.print("nice = {d}\n", .{n});
    if (in.command == .native) {
        for (u.limits) |l| for (rlimit_keys) |k| {
            if (!std.mem.eql(u8, l.key, k.systemd)) continue;
            try w.print("{s} = ", .{k.dinit});
            try writeLimit(w, l.value);
            try w.writeByte('\n');
        };
    }
    if (in.kind == .bgprocess) {
        if (u.pid_file) |p| {
            try w.writeAll("pid-file = ");
            try writeWord(w, p, true);
            try w.writeByte('\n');
        }
    }
    try writeDeps(w, "depends-on", in.deps.depends_on);
    try writeDeps(w, "waits-for", in.deps.waits_for);
    try writeDeps(w, "after", in.deps.after);
    try writeDeps(w, "before", in.deps.before);
    if (in.log_file) |path| {
        try w.writeAll("logfile = ");
        try writeWord(w, path, true);
        try w.print("\nlogfile-permissions = {s}\n", .{log_permissions});
    }
}

pub fn renderAlloc(gpa: Allocator, in: Input) Allocator.Error![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    render(&aw.writer, in) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

const testing = std.testing;

fn expectWord(expected: []const u8, word: []const u8, literal: bool) !void {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeWord(&w, word, literal);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "words are quoted and escaped for dinit" {
    try expectWord("plain", "plain", false);
    try expectWord("\"a b\"", "a b", false);
    try expectWord("\"\"", "", false);
    try expectWord("\"a#b\"", "a#b", false);
    try expectWord("a\\\\b", "a\\b", false);
    try expectWord("\"say \\\"hi\\\"\"", "say \"hi\"", false);
    try expectWord("price$$5", "price$$5", false);
    try expectWord("price$$5", "price$5", true);
    try expectWord("--opt=a=b", "--opt=a=b", false);
}

fn expectSeconds(expected: []const u8, usec: u64) !void {
    var buf: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeSeconds(&w, usec);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "microseconds become seconds with up to three decimals" {
    try expectSeconds("5", 5_000_000);
    try expectSeconds("0.1", 100_000);
    try expectSeconds("1.5", 1_500_000);
    try expectSeconds("0.001", 1);
    try expectSeconds("90", 90_000_000);
    try expectSeconds("0.25", 250_000);
    try expectSeconds("0", timespan.infinity);
    try expectSeconds("0", 0);
}

test "signal names lose the SIG prefix and numbers are rejected" {
    try testing.expectEqualStrings("USR1", signalName("SIGUSR1").?);
    try testing.expectEqualStrings("HUP", signalName("HUP").?);
    try testing.expect(signalName("9") == null);
    try testing.expect(signalName("sigterm") == null);
    try testing.expect(signalName("SIG") == null);
}
