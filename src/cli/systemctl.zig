// SPDX-License-Identifier: GPL-3.0-or-later
//! `systemctl` argument parser (spec §3.1–§3.2). Strings in a `Request` borrow from the
//! argument slice passed to `parse`; only the slices holding them are allocated.
const std = @import("std");
const Io = std.Io;
const Scope = @import("../core/types.zig").Scope;

pub const Verb = enum {
    daemon_reload,
    daemon_reexec,
    start,
    stop,
    restart,
    try_restart,
    reload,
    reload_or_restart,
    try_reload_or_restart,
    enable,
    disable,
    reenable,
    mask,
    unmask,
    revert,
    is_active,
    is_enabled,
    is_failed,
    status,
    show,
    cat,
    edit,
    list_units,
    list_unit_files,
    list_timers,
    is_system_running,
    preset,
    preset_all,
    kill,
    reboot,
    poweroff,
    halt,
    suspend_,
    hibernate,
    set_property,
    set_environment,
    unset_environment,
    import_environment,

    pub fn name(verb: Verb) []const u8 {
        return verb_names[@backingInt(verb)];
    }

    pub fn fromName(text: []const u8) ?Verb {
        for (verb_names, 0..) |n, i| {
            if (std.mem.eql(u8, n, text)) return @fromBackingInt(@intCast(i));
        }
        return null;
    }

    /// Verbs that change the system and are therefore subject to `--dry-run`.
    pub fn mutates(verb: Verb) bool {
        return switch (verb) {
            .daemon_reload, .daemon_reexec, .enable, .disable, .reenable, .mask, .unmask, .revert, .edit, .preset, .preset_all => true,
            else => false,
        };
    }
};

const verb_names = blk: {
    const fields = std.meta.fieldNames(Verb);
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |name, i| {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, j| buf[j] = if (c == '_') '-' else c;
        const trimmed = std.mem.trimEnd(u8, &buf, "-");
        const final = buf[0..trimmed.len].*;
        names[i] = &final;
    }
    break :blk names;
};

pub const Command = union(enum) {
    known: Verb,
    /// Verb not in §3.1, preserved verbatim.
    unknown: []const u8,

    pub fn parse(word: []const u8) Command {
        return if (Verb.fromName(word)) |v| .{ .known = v } else .{ .unknown = word };
    }

    pub fn text(command: Command) []const u8 {
        return switch (command) {
            .known => |v| v.name(),
            .unknown => |s| s,
        };
    }
};

pub const Mode = enum { run, help, version };

pub const Options = struct {
    scope: Scope = .system,
    global: bool = false,
    now: bool = false,
    quiet: bool = false,
    force: bool = false,
    no_reload: bool = false,
    no_block: bool = false,
    no_ask_password: bool = false,
    no_wall: bool = false,
    no_pager: bool = false,
    no_legend: bool = false,
    plain: bool = false,
    full: bool = false,
    all: bool = false,
    /// `-t` / `--type` values, comma-separated lists split.
    types: []const []const u8 = &.{},
    /// `--state` values, comma-separated lists split.
    states: []const []const u8 = &.{},
    /// `-p` / `-P` / `--property` values, comma-separated lists split.
    properties: []const []const u8 = &.{},
    value: bool = false,
    lines: ?u32 = null,
    output: ?[]const u8 = null,
    runtime: bool = false,
    root: ?[]const u8 = null,
    dry_run: bool = false,
};

/// Option that is parsed and recorded but has no effect; callers report it once at `info` level.
pub const Ignored = struct {
    /// Canonical long name without dashes (`kill-whom` for `--kill-who`, `check-inhibitors` for `-i`).
    name: []const u8,
    value: ?[]const u8 = null,
};

pub const Request = struct {
    mode: Mode = .run,
    /// Null when no verb was given.
    command: ?Command = null,
    /// Raw unit arguments after the verb.
    units: []const []const u8 = &.{},
    options: Options = .{},
    ignored: []const Ignored = &.{},
    /// Unrecognised options as written (`--foo=1`, `-Z`); callers warn and continue.
    unknown_options: []const []const u8 = &.{},
};

pub const Failure = struct {
    kind: Kind,
    /// Offending option as written, including dashes (`-H`, `--host`).
    arg: []const u8,

    pub const Kind = enum { unsupported_remote, unknown_option, missing_value, invalid_value, unexpected_value };

    pub fn format(f: Failure, w: *Io.Writer) Io.Writer.Error!void {
        switch (f.kind) {
            .unsupported_remote => try w.print("option '{s}' is not supported: remote, container, capsule and image operation is unavailable", .{f.arg}),
            .unknown_option => try w.print("unrecognized option '{s}'", .{f.arg}),
            .missing_value => try w.print("option '{s}' requires an argument", .{f.arg}),
            .invalid_value => try w.print("invalid argument for option '{s}'", .{f.arg}),
            .unexpected_value => try w.print("option '{s}' doesn't allow an argument", .{f.arg}),
        }
    }
};

pub const Result = union(enum) {
    ok: Request,
    err: Failure,
};

pub const help_text =
    \\systemctl [OPTIONS...] COMMAND [UNIT...]
    \\
    \\Query or send control commands to the init system, as translated by fake-systemd.
    \\
;

const Opt = enum {
    system,
    user,
    global,
    now,
    quiet,
    force,
    no_reload,
    no_block,
    no_ask_password,
    no_wall,
    no_pager,
    no_legend,
    legend,
    plain,
    full,
    all,
    type,
    state,
    failed,
    property,
    P,
    value,
    lines,
    output,
    runtime,
    root,
    dry_run,
    host,
    machine,
    version,
    help,
    /// Accepted and recorded in `Request.ignored`.
    ignored,
};

const Entry = struct {
    opt: Opt,
    takes_value: bool = false,
    /// Canonical long name without dashes, for `.ignored` entries.
    name: []const u8 = "",
    /// Value implied by a flag that is a shortcut for `--name=implied`.
    implied: ?[]const u8 = null,
};

fn flag(opt: Opt) Entry {
    return .{ .opt = opt };
}

fn valued(opt: Opt) Entry {
    return .{ .opt = opt, .takes_value = true };
}

fn ignoredFlag(name: []const u8) Entry {
    return .{ .opt = .ignored, .name = name };
}

fn ignoredValue(name: []const u8) Entry {
    return .{ .opt = .ignored, .takes_value = true, .name = name };
}

const LongOption = struct { []const u8, Entry };

/// Long options of systemctl 257 (`systemctl --help` and systemctl(1)), plus the deprecated
/// aliases it still accepts.
const long_options = [_]LongOption{
    .{ "system", flag(.system) },
    .{ "user", flag(.user) },
    .{ "global", flag(.global) },
    .{ "now", flag(.now) },
    .{ "quiet", flag(.quiet) },
    .{ "force", flag(.force) },
    .{ "no-reload", flag(.no_reload) },
    .{ "no-block", flag(.no_block) },
    .{ "no-ask-password", flag(.no_ask_password) },
    .{ "no-wall", flag(.no_wall) },
    .{ "no-pager", flag(.no_pager) },
    .{ "no-legend", flag(.no_legend) },
    .{ "legend", valued(.legend) },
    .{ "plain", flag(.plain) },
    .{ "full", flag(.full) },
    .{ "all", flag(.all) },
    .{ "type", valued(.type) },
    .{ "state", valued(.state) },
    .{ "failed", flag(.failed) },
    .{ "property", valued(.property) },
    .{ "value", flag(.value) },
    .{ "lines", valued(.lines) },
    .{ "output", valued(.output) },
    .{ "runtime", flag(.runtime) },
    .{ "root", valued(.root) },
    .{ "dry-run", flag(.dry_run) },
    .{ "host", valued(.host) },
    .{ "machine", valued(.machine) },
    .{ "version", flag(.version) },
    .{ "help", flag(.help) },
    .{ "capsule", valued(.host) },
    .{ "job-mode", ignoredValue("job-mode") },
    .{ "check-inhibitors", ignoredValue("check-inhibitors") },
    .{ "kill-whom", ignoredValue("kill-whom") },
    .{ "kill-who", ignoredValue("kill-whom") },
    .{ "kill-value", ignoredValue("kill-value") },
    .{ "signal", ignoredValue("signal") },
    .{ "what", ignoredValue("what") },
    .{ "message", ignoredValue("message") },
    .{ "preset-mode", ignoredValue("preset-mode") },
    .{ "image", valued(.host) },
    .{ "image-policy", valued(.host) },
    .{ "boot-loader-menu", ignoredValue("boot-loader-menu") },
    .{ "boot-loader-entry", ignoredValue("boot-loader-entry") },
    .{ "reboot-argument", ignoredValue("reboot-argument") },
    .{ "timestamp", ignoredValue("timestamp") },
    .{ "drop-in", ignoredValue("drop-in") },
    .{ "when", ignoredValue("when") },
    .{ "recursive", ignoredFlag("recursive") },
    .{ "reverse", ignoredFlag("reverse") },
    .{ "before", ignoredFlag("before") },
    .{ "after", ignoredFlag("after") },
    .{ "with-dependencies", ignoredFlag("with-dependencies") },
    .{ "show-transaction", ignoredFlag("show-transaction") },
    .{ "show-types", ignoredFlag("show-types") },
    .{ "no-warn", ignoredFlag("no-warn") },
    .{ "wait", ignoredFlag("wait") },
    .{ "firmware-setup", ignoredFlag("firmware-setup") },
    .{ "read-only", ignoredFlag("read-only") },
    .{ "mkdir", ignoredFlag("mkdir") },
    .{ "marked", ignoredFlag("marked") },
    .{ "stdin", ignoredFlag("stdin") },
    .{ "fail", ignoredFlag("fail") },
    .{ "irreversible", ignoredFlag("irreversible") },
    .{ "ignore-dependencies", ignoredFlag("ignore-dependencies") },
    .{ "ignore-inhibitors", ignoredFlag("ignore-inhibitors") },
};

fn longOption(name: []const u8) ?Entry {
    for (long_options) |o| {
        if (std.mem.eql(u8, name, o[0])) return o[1];
    }
    return null;
}

fn shortOption(c: u8) ?Entry {
    return switch (c) {
        'q' => flag(.quiet),
        'f' => flag(.force),
        'l' => flag(.full),
        'a' => flag(.all),
        't' => valued(.type),
        'p' => valued(.property),
        'P' => valued(.P),
        'n' => valued(.lines),
        'o' => valued(.output),
        'H' => valued(.host),
        'M' => valued(.machine),
        'h' => flag(.help),
        's' => ignoredValue("signal"),
        'C' => valued(.host),
        'r' => ignoredFlag("recursive"),
        'T' => ignoredFlag("show-transaction"),
        'i' => .{ .opt = .ignored, .name = "check-inhibitors", .implied = "no" },
        else => null,
    };
}

pub const Origin = union(enum) {
    /// Option as written, including dashes.
    long: []const u8,
    short: u8,
};

const State = struct {
    gpa: std.mem.Allocator,
    opts: Options = .{},
    mode: Mode = .run,
    types: std.ArrayList([]const u8) = .empty,
    states: std.ArrayList([]const u8) = .empty,
    properties: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,
    ignored: std.ArrayList(Ignored) = .empty,
    unknown: std.ArrayList([]const u8) = .empty,
    failure: ?Failure = null,

    fn fail(s: *State, kind: Failure.Kind, origin: Origin) !void {
        if (s.failure != null) return;
        const arg = switch (origin) {
            .long => |text| text,
            .short => |c| try std.fmt.allocPrint(s.gpa, "-{c}", .{c}),
        };
        s.failure = .{ .kind = kind, .arg = arg };
    }

    fn apply(s: *State, entry: Entry, value: ?[]const u8, origin: Origin) !void {
        switch (entry.opt) {
            .system => s.opts.scope = .system,
            .user => s.opts.scope = .user,
            .global => s.opts.global = true,
            .now => s.opts.now = true,
            .quiet => s.opts.quiet = true,
            .force => s.opts.force = true,
            .no_reload => s.opts.no_reload = true,
            .no_block => s.opts.no_block = true,
            .no_ask_password => s.opts.no_ask_password = true,
            .no_wall => s.opts.no_wall = true,
            .no_pager => s.opts.no_pager = true,
            .no_legend => s.opts.no_legend = true,
            .legend => {
                const on = parseBool(value.?) orelse return s.fail(.invalid_value, origin);
                s.opts.no_legend = !on;
            },
            .plain => s.opts.plain = true,
            .full => s.opts.full = true,
            .all => s.opts.all = true,
            .value => s.opts.value = true,
            .runtime => s.opts.runtime = true,
            .dry_run => s.opts.dry_run = true,
            .version => s.mode = .version,
            .help => s.mode = .help,
            .type => try splitInto(s.gpa, &s.types, value.?),
            .state => try splitInto(s.gpa, &s.states, value.?),
            .failed => try s.states.append(s.gpa, "failed"),
            .property => try splitInto(s.gpa, &s.properties, value.?),
            .P => {
                try splitInto(s.gpa, &s.properties, value.?);
                s.opts.value = true;
            },
            .lines => s.opts.lines = std.fmt.parseInt(u32, value.?, 10) catch return s.fail(.invalid_value, origin),
            .output => s.opts.output = value.?,
            .root => s.opts.root = value.?,
            .host, .machine => try s.fail(.unsupported_remote, origin),
            .ignored => try s.ignored.append(s.gpa, .{ .name = entry.name, .value = value orelse entry.implied }),
        }
    }

    fn warnUnknown(s: *State, arg: []const u8) !void {
        try s.unknown.append(s.gpa, arg);
    }
};

fn parseBool(text: []const u8) ?bool {
    const yes = [_][]const u8{ "1", "yes", "true", "on", "y", "t" };
    const no = [_][]const u8{ "0", "no", "false", "off", "n", "f" };
    for (yes) |y| if (std.ascii.eqlIgnoreCase(text, y)) return true;
    for (no) |n| if (std.ascii.eqlIgnoreCase(text, n)) return false;
    return null;
}

fn splitInto(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        if (part.len > 0) try list.append(gpa, part);
    }
}

/// Parses `args` (without the program name). Options may appear before or after the verb;
/// an option that takes a value always consumes the next argument when none is attached.
/// Unrecognised options are collected in `Request.unknown_options` and otherwise ignored.
pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) error{OutOfMemory}!Result {
    var s: State = .{ .gpa = gpa };
    var i: usize = 0;
    var only_positional = false;
    while (i < args.len and s.failure == null) : (i += 1) {
        const arg = args[i];
        if (only_positional or arg.len < 2 or arg[0] != '-') {
            try s.positional.append(gpa, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            only_positional = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            const body = arg[2..];
            const eq = std.mem.findScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;
            const shown = arg[0 .. 2 + name.len];
            const entry = longOption(name) orelse {
                try s.warnUnknown(arg);
                continue;
            };
            var value: ?[]const u8 = null;
            if (entry.takes_value) {
                if (eq) |e| {
                    value = body[e + 1 ..];
                } else if (i + 1 < args.len) {
                    i += 1;
                    value = args[i];
                } else {
                    try s.fail(.missing_value, .{ .long = shown });
                    break;
                }
            } else if (eq != null) {
                try s.fail(.unexpected_value, .{ .long = shown });
                break;
            }
            try s.apply(entry, value, .{ .long = shown });
        } else {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const entry = shortOption(arg[j]) orelse {
                    try s.warnUnknown(try std.fmt.allocPrint(gpa, "-{c}", .{arg[j]}));
                    continue;
                };
                if (!entry.takes_value) {
                    try s.apply(entry, null, .{ .short = arg[j] });
                    continue;
                }
                var value: []const u8 = undefined;
                if (j + 1 < arg.len) {
                    value = arg[j + 1 ..];
                } else if (i + 1 < args.len) {
                    i += 1;
                    value = args[i];
                } else {
                    try s.fail(.missing_value, .{ .short = arg[j] });
                    break;
                }
                try s.apply(entry, value, .{ .short = arg[j] });
                break;
            }
        }
    }
    if (s.failure) |f| return .{ .err = f };
    s.opts.types = try s.types.toOwnedSlice(gpa);
    s.opts.states = try s.states.toOwnedSlice(gpa);
    s.opts.properties = try s.properties.toOwnedSlice(gpa);
    var request: Request = .{
        .mode = s.mode,
        .options = s.opts,
        .ignored = try s.ignored.toOwnedSlice(gpa),
        .unknown_options = try s.unknown.toOwnedSlice(gpa),
    };
    if (s.positional.items.len > 0) {
        request.command = .parse(s.positional.items[0]);
        request.units = try gpa.dupe([]const u8, s.positional.items[1..]);
    }
    return .{ .ok = request };
}

const testing = std.testing;

fn parseOk(arena: std.mem.Allocator, args: []const []const u8) !Request {
    return switch (try parse(arena, args)) {
        .ok => |r| r,
        .err => |f| {
            std.debug.print("unexpected failure {t} {s}\n", .{ f.kind, f.arg });
            return error.TestUnexpectedResult;
        },
    };
}

fn parseErr(arena: std.mem.Allocator, args: []const []const u8) !Failure {
    return switch (try parse(arena, args)) {
        .ok => error.TestUnexpectedResult,
        .err => |f| f,
    };
}

fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "every verb name round-trips and maps to its enum value" {
    for (std.enums.values(Verb)) |v| {
        try testing.expectEqual(v, Verb.fromName(v.name()).?);
    }
    try testing.expectEqualStrings("daemon-reload", Verb.daemon_reload.name());
    try testing.expectEqualStrings("try-reload-or-restart", Verb.try_reload_or_restart.name());
    try testing.expectEqualStrings("list-unit-files", Verb.list_unit_files.name());
    try testing.expectEqualStrings("suspend", Verb.suspend_.name());
    try testing.expectEqualStrings("is-system-running", Verb.is_system_running.name());
    try testing.expect(Verb.fromName("daemon_reload") == null);
    try testing.expect(Verb.fromName("") == null);
}

test "all verbs of the contract are recognised" {
    const names = [_][]const u8{
        "daemon-reload",     "daemon-reexec",      "start",                 "stop",       "restart",      "try-restart",
        "reload",            "reload-or-restart",  "try-reload-or-restart", "enable",     "disable",      "reenable",
        "mask",              "unmask",             "revert",                "is-active",  "is-enabled",   "is-failed",
        "status",            "show",               "cat",                   "edit",       "list-units",   "list-unit-files",
        "list-timers",       "is-system-running",  "preset",                "preset-all", "kill",         "reboot",
        "poweroff",          "halt",               "suspend",               "hibernate",  "set-property", "set-environment",
        "unset-environment", "import-environment",
    };
    try testing.expectEqual(names.len, std.meta.fieldNames(Verb).len);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (names) |n| {
        const r = try parseOk(arena.allocator(), &.{ n, "foo" });
        try testing.expectEqualStrings(n, r.command.?.known.name());
    }
}

test "unknown verb is preserved as a string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "list-dependencies", "foo.service" });
    try testing.expectEqualStrings("list-dependencies", r.command.?.unknown);
    try testing.expectEqualStrings("list-dependencies", r.command.?.text());
    try expectStrings(&.{"foo.service"}, r.units);
}

test "no arguments yields no command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{});
    try testing.expect(r.command == null);
    try testing.expectEqual(@as(usize, 0), r.units.len);
    try testing.expectEqual(Mode.run, r.mode);
    try testing.expectEqual(Scope.system, r.options.scope);
}

test "units stay raw and keep their order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "start", "foo", "bar.timer", "baz@x.service", "../x", "foo-*" });
    try testing.expectEqual(Verb.start, r.command.?.known);
    try expectStrings(&.{ "foo", "bar.timer", "baz@x.service", "../x", "foo-*" }, r.units);
}

test "boolean long options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{
        "--user",     "--global",          "--now",     "--quiet",    "--force",     "--no-reload",
        "--no-block", "--no-ask-password", "--no-wall", "--no-pager", "--no-legend", "--plain",
        "--full",     "--all",             "--value",   "--runtime",  "--dry-run",   "enable",
        "foo",
    });
    const o = r.options;
    try testing.expectEqual(Scope.user, o.scope);
    try testing.expect(o.global and o.now and o.quiet and o.force and o.no_reload);
    try testing.expect(o.no_block and o.no_ask_password and o.no_wall and o.no_pager);
    try testing.expect(o.no_legend and o.plain and o.full and o.all and o.value);
    try testing.expect(o.runtime and o.dry_run);
    try testing.expectEqual(Verb.enable, r.command.?.known);
}

test "last scope option wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(Scope.system, (try parseOk(arena.allocator(), &.{ "--user", "--system", "status" })).options.scope);
    try testing.expectEqual(Scope.user, (try parseOk(arena.allocator(), &.{ "--system", "--user", "status" })).options.scope);
}

test "value options in separate and attached forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sep = try parseOk(a, &.{ "list-units", "--type", "service", "--state", "failed", "--lines", "7", "--output", "cat", "--root", "/mnt" });
    const att = try parseOk(a, &.{ "list-units", "--type=service", "--state=failed", "--lines=7", "--output=cat", "--root=/mnt" });
    for ([_]Request{ sep, att }) |r| {
        try expectStrings(&.{"service"}, r.options.types);
        try expectStrings(&.{"failed"}, r.options.states);
        try testing.expectEqual(@as(?u32, 7), r.options.lines);
        try testing.expectEqualStrings("cat", r.options.output.?);
        try testing.expectEqualStrings("/mnt", r.options.root.?);
        try testing.expectEqual(@as(usize, 0), r.units.len);
    }
}

test "attached value may contain equals signs and be empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "--root=/a=b", "--output=", "status" });
    try testing.expectEqualStrings("/a=b", r.options.root.?);
    try testing.expectEqualStrings("", r.options.output.?);
}

test "short options with attached and separate values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "show", "-t", "timer", "-p", "Id", "-n", "5", "-o", "short", "foo" });
    try expectStrings(&.{"timer"}, r1.options.types);
    try expectStrings(&.{"Id"}, r1.options.properties);
    try testing.expectEqual(@as(?u32, 5), r1.options.lines);
    try testing.expectEqualStrings("short", r1.options.output.?);
    try expectStrings(&.{"foo"}, r1.units);

    const r2 = try parseOk(a, &.{ "show", "-tservice", "-pFoo", "-n5", "-ocat", "foo" });
    try expectStrings(&.{"service"}, r2.options.types);
    try expectStrings(&.{"Foo"}, r2.options.properties);
    try testing.expectEqual(@as(?u32, 5), r2.options.lines);
    try testing.expectEqualStrings("cat", r2.options.output.?);
    try expectStrings(&.{"foo"}, r2.units);
}

test "combined short flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "-qa", "list-units" });
    try testing.expect(r1.options.quiet and r1.options.all);
    try testing.expectEqual(Verb.list_units, r1.command.?.known);

    const r2 = try parseOk(a, &.{ "-qfl", "status", "x" });
    try testing.expect(r2.options.quiet and r2.options.force and r2.options.full);

    const r3 = try parseOk(a, &.{ "-qpFoo", "show", "x" });
    try testing.expect(r3.options.quiet);
    try expectStrings(&.{"Foo"}, r3.options.properties);
    try expectStrings(&.{"x"}, r3.units);

    const r4 = try parseOk(a, &.{ "-qn5", "status", "x" });
    try testing.expect(r4.options.quiet);
    try testing.expectEqual(@as(?u32, 5), r4.options.lines);

    const r5 = try parseOk(a, &.{ "-ap", "Id", "show", "x" });
    try testing.expect(r5.options.all);
    try expectStrings(&.{"Id"}, r5.options.properties);
    try expectStrings(&.{"x"}, r5.units);
}

test "the value of -p is never taken as a unit or verb" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "show", "-p", "ActiveState", "foo.service" });
    try expectStrings(&.{"foo.service"}, r1.units);
    try expectStrings(&.{"ActiveState"}, r1.options.properties);

    const r2 = try parseOk(a, &.{ "-p", "MainPID", "show", "foo" });
    try testing.expectEqual(Verb.show, r2.command.?.known);
    try expectStrings(&.{"foo"}, r2.units);

    const r3 = try parseOk(a, &.{ "show", "foo", "--property", "Id" });
    try expectStrings(&.{"foo"}, r3.units);
    try expectStrings(&.{"Id"}, r3.options.properties);

    const r4 = try parseOk(a, &.{ "show", "--property", "start", "foo" });
    try expectStrings(&.{"start"}, r4.options.properties);
    try expectStrings(&.{"foo"}, r4.units);
}

test "a value-taking option consumes a following dash argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "show", "--property", "-x", "foo" });
    try expectStrings(&.{"-x"}, r.options.properties);
    try expectStrings(&.{"foo"}, r.units);
}

test "comma separated lists are split and repeatable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "show", "-p", "Id,Names,,", "-p", "Type", "-t", "service,timer", "--state=active,failed", "foo" });
    try expectStrings(&.{ "Id", "Names", "Type" }, r.options.properties);
    try expectStrings(&.{ "service", "timer" }, r.options.types);
    try expectStrings(&.{ "active", "failed" }, r.options.states);
}

test "-P sets the property and --value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "show", "-P", "MainPID", "foo" });
    try expectStrings(&.{"MainPID"}, r1.options.properties);
    try testing.expect(r1.options.value);
    try expectStrings(&.{"foo"}, r1.units);
    const r2 = try parseOk(a, &.{ "show", "-PMainPID", "foo" });
    try expectStrings(&.{"MainPID"}, r2.options.properties);
    try testing.expect(r2.options.value);
    const r3 = try parseOk(a, &.{ "show", "foo" });
    try testing.expect(!r3.options.value);
}

test "terminator makes everything positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "-q", "status", "--", "-weird", "--now", "foo" });
    try testing.expect(r1.options.quiet and !r1.options.now);
    try expectStrings(&.{ "-weird", "--now", "foo" }, r1.units);
    const r2 = try parseOk(a, &.{ "--", "--start", "x" });
    try testing.expectEqualStrings("--start", r2.command.?.unknown);
    try expectStrings(&.{"x"}, r2.units);
    const r3 = try parseOk(a, &.{ "status", "--", "--" });
    try expectStrings(&.{"--"}, r3.units);
}

test "a lone dash is positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "status", "-" });
    try expectStrings(&.{"-"}, r.units);
}

test "options may follow the verb and units" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "enable", "foo", "--now", "bar", "-q" });
    try expectStrings(&.{ "foo", "bar" }, r.units);
    try testing.expect(r.options.now and r.options.quiet);
}

test "host and machine options produce a dedicated error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "-H", "root@box", "status" }, "-H" },
        .{ &.{ "-Hroot@box", "status" }, "-H" },
        .{ &.{ "status", "--host", "box" }, "--host" },
        .{ &.{ "--host=box", "status" }, "--host" },
        .{ &.{ "-M", "c1", "status" }, "-M" },
        .{ &.{ "-qMc1", "status" }, "-M" },
        .{ &.{ "--machine=c1", "status" }, "--machine" },
        .{ &.{ "--machine", "c1" }, "--machine" },
    };
    for (cases) |c| {
        const f = try parseErr(a, c[0]);
        try testing.expectEqual(Failure.Kind.unsupported_remote, f.kind);
        try testing.expectEqualStrings(c[1], f.arg);
    }
}

test "missing values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f1 = try parseErr(a, &.{ "show", "--property" });
    try testing.expectEqual(Failure.Kind.missing_value, f1.kind);
    try testing.expectEqualStrings("--property", f1.arg);
    const f2 = try parseErr(a, &.{ "show", "-qp" });
    try testing.expectEqual(Failure.Kind.missing_value, f2.kind);
    try testing.expectEqualStrings("-p", f2.arg);
}

test "invalid and unexpected values, unknown options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f1 = try parseErr(a, &.{ "status", "-n", "many" });
    try testing.expectEqual(Failure.Kind.invalid_value, f1.kind);
    try testing.expectEqualStrings("-n", f1.arg);
    const f2 = try parseErr(a, &.{ "status", "--lines=-1" });
    try testing.expectEqual(Failure.Kind.invalid_value, f2.kind);
    try testing.expectEqualStrings("--lines", f2.arg);
    const f3 = try parseErr(a, &.{ "status", "--now=yes" });
    try testing.expectEqual(Failure.Kind.unexpected_value, f3.kind);
    try testing.expectEqualStrings("--now", f3.arg);
}

test "the first failure is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try parseErr(arena.allocator(), &.{ "--now=1", "-H", "x" });
    try testing.expectEqual(Failure.Kind.unexpected_value, f.kind);
}

test "failure messages" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try (Failure{ .kind = .unknown_option, .arg = "--bogus" }).format(&w);
    try testing.expectEqualStrings("unrecognized option '--bogus'", w.buffered());
    w = .fixed(&buf);
    try (Failure{ .kind = .unsupported_remote, .arg = "-H" }).format(&w);
    try testing.expect(std.mem.startsWith(u8, w.buffered(), "option '-H' is not supported"));
}

test "version and help modes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Mode.version, (try parseOk(a, &.{"--version"})).mode);
    try testing.expectEqual(Mode.help, (try parseOk(a, &.{"-h"})).mode);
    try testing.expectEqual(Mode.help, (try parseOk(a, &.{"--help"})).mode);
    try testing.expectEqual(Mode.help, (try parseOk(a, &.{ "-qh", "status" })).mode);
}

test "mutating verbs" {
    try testing.expect(Verb.enable.mutates());
    try testing.expect(Verb.daemon_reload.mutates());
    try testing.expect(!Verb.status.mutates());
    try testing.expect(!Verb.start.mutates());
}

test "out of memory is propagated" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parse(failing.allocator(), &.{ "start", "foo" }));
}

test "--legend takes a boolean" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try parseOk(a, &.{ "--legend=false", "list-unit-files" })).options.no_legend);
    try testing.expect((try parseOk(a, &.{ "--legend", "no", "list-unit-files" })).options.no_legend);
    try testing.expect(!(try parseOk(a, &.{ "--no-legend", "--legend=yes", "list-unit-files" })).options.no_legend);
    const f = try parseErr(a, &.{"--legend=maybe"});
    try testing.expectEqual(Failure.Kind.invalid_value, f.kind);
    try testing.expectEqualStrings("--legend", f.arg);
}

fn hasIgnored(r: Request, name: []const u8, value: ?[]const u8) bool {
    for (r.ignored) |ig| {
        if (!std.mem.eql(u8, ig.name, name)) continue;
        if (value == null and ig.value == null) return true;
        if (value != null and ig.value != null and std.mem.eql(u8, value.?, ig.value.?)) return true;
    }
    return false;
}

const ignored_valued = [_][]const u8{
    "--job-mode",        "--check-inhibitors", "--kill-whom",   "--kill-value",       "--signal",
    "--what",            "--message",          "--preset-mode", "--boot-loader-menu", "--boot-loader-entry",
    "--reboot-argument", "--timestamp",        "--drop-in",     "--when",
};

const ignored_flags = [_][]const u8{
    "--recursive",        "--reverse",             "--before",            "--after", "--with-dependencies",
    "--show-transaction", "--show-types",          "--no-warn",           "--wait",  "--firmware-setup",
    "--read-only",        "--mkdir",               "--marked",            "--stdin", "--fail",
    "--irreversible",     "--ignore-dependencies", "--ignore-inhibitors",
};

test "every ignored value option takes a value in both forms and never yields a unit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (ignored_valued) |opt| {
        const sep = try parseOk(a, &.{ "restart", opt, "VALUE", "foo.service" });
        try expectStrings(&.{"foo.service"}, sep.units);
        try testing.expect(hasIgnored(sep, opt[2..], "VALUE"));
        try testing.expectEqual(@as(usize, 0), sep.unknown_options.len);

        const eq_arg = try std.fmt.allocPrint(a, "{s}=VALUE", .{opt});
        const att = try parseOk(a, &.{ "restart", eq_arg, "foo.service" });
        try expectStrings(&.{"foo.service"}, att.units);
        try testing.expect(hasIgnored(att, opt[2..], "VALUE"));

        const before_verb = try parseOk(a, &.{ opt, "restart", "stop", "foo.service" });
        try testing.expectEqual(Verb.stop, before_verb.command.?.known);
        try expectStrings(&.{"foo.service"}, before_verb.units);

        const missing = try parseErr(a, &.{ "status", opt });
        try testing.expectEqual(Failure.Kind.missing_value, missing.kind);
        try testing.expectEqualStrings(opt, missing.arg);
    }
}

test "every ignored flag takes no value and consumes no argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (ignored_flags) |opt| {
        const r = try parseOk(a, &.{ "status", opt, "foo.service" });
        try expectStrings(&.{"foo.service"}, r.units);
        try testing.expect(hasIgnored(r, opt[2..], null));
        try testing.expectEqual(@as(usize, 0), r.unknown_options.len);
        const bad = try parseErr(a, &.{ "status", try std.fmt.allocPrint(a, "{s}=1", .{opt}) });
        try testing.expectEqual(Failure.Kind.unexpected_value, bad.kind);
    }
}

test "short options that are accepted and ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "kill", "-s", "TERM", "foo" });
    try expectStrings(&.{"foo"}, r1.units);
    try testing.expect(hasIgnored(r1, "signal", "TERM"));
    const r2 = try parseOk(a, &.{ "kill", "-sHUP", "foo" });
    try testing.expect(hasIgnored(r2, "signal", "HUP"));
    const r3 = try parseOk(a, &.{ "-riT", "list-dependencies", "foo" });
    try testing.expect(hasIgnored(r3, "recursive", null));
    try testing.expect(hasIgnored(r3, "check-inhibitors", "no"));
    try testing.expect(hasIgnored(r3, "show-transaction", null));
    try expectStrings(&.{"foo"}, r3.units);
    const r5 = try parseOk(a, &.{ "--kill-who=main", "kill", "foo" });
    try testing.expect(hasIgnored(r5, "kill-whom", "main"));
}

test "--failed is a shortcut for --state=failed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "list-units", "--failed", "--state=active" });
    try expectStrings(&.{ "failed", "active" }, r.options.states);
    try testing.expectEqual(@as(usize, 0), r.ignored.len);
}

test "acted-on options are not recorded as ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "--now", "-q", "-t", "service", "enable", "foo" });
    try testing.expectEqual(@as(usize, 0), r.ignored.len);
    try testing.expectEqual(@as(usize, 0), r.unknown_options.len);
}

test "unknown options are collected, with their attached value, and ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r1 = try parseOk(a, &.{ "status", "--bogus=1", "foo" });
    try expectStrings(&.{"--bogus=1"}, r1.unknown_options);
    try expectStrings(&.{"foo"}, r1.units);
    const r2 = try parseOk(a, &.{ "status", "--bogus", "foo" });
    try expectStrings(&.{"--bogus"}, r2.unknown_options);
    try expectStrings(&.{"foo"}, r2.units);
    const r3 = try parseOk(a, &.{ "-qZa", "list-units" });
    try expectStrings(&.{"-Z"}, r3.unknown_options);
    try testing.expect(r3.options.quiet and r3.options.all);
    const r4 = try parseOk(a, &.{ "--zzz", "--yyy=2", "-X", "start", "foo" });
    try expectStrings(&.{ "--zzz", "--yyy=2", "-X" }, r4.unknown_options);
    try testing.expectEqual(Verb.start, r4.command.?.known);
    try expectStrings(&.{"foo"}, r4.units);
}

test "unknown options after the terminator are units" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "status", "--", "--bogus" });
    try testing.expectEqual(@as(usize, 0), r.unknown_options.len);
    try expectStrings(&.{"--bogus"}, r.units);
}

test "host and machine stay hard errors next to unknown options" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const f = try parseErr(arena.allocator(), &.{ "--bogus", "-H", "x", "status" });
    try testing.expectEqual(Failure.Kind.unsupported_remote, f.kind);
}

test "image and capsule options are hard errors like host and machine" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const []const u8, []const u8 }{
        .{ &.{ "--image", "disk.raw", "status" }, "--image" },
        .{ &.{ "--image=disk.raw", "status" }, "--image" },
        .{ &.{ "status", "--image-policy", "root=verity", "foo" }, "--image-policy" },
        .{ &.{ "--image-policy=*", "status" }, "--image-policy" },
        .{ &.{ "-C", "cap", "status" }, "-C" },
        .{ &.{ "-qCcap", "status" }, "-C" },
        .{ &.{ "--capsule", "cap", "status" }, "--capsule" },
        .{ &.{ "--capsule=cap", "status" }, "--capsule" },
    };
    for (cases) |c| {
        const f = try parseErr(a, c[0]);
        try testing.expectEqual(Failure.Kind.unsupported_remote, f.kind);
        try testing.expectEqualStrings(c[1], f.arg);
    }
    const missing = try parseErr(a, &.{ "status", "--image" });
    try testing.expectEqual(Failure.Kind.missing_value, missing.kind);
}
