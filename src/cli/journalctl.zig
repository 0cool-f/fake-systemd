//! `journalctl` argument parser (spec §3.5). Strings in a `Request` borrow from the argument
//! slice passed to `parse`.
const std = @import("std");
const systemctl = @import("systemctl.zig");

pub const Failure = systemctl.Failure;
pub const Mode = systemctl.Mode;

pub const Output = enum { short, cat };

pub const Lines = union(enum) {
    count: u32,
    all,
};

pub const default_lines: u32 = 10;
pub const pager_end_lines: u32 = 1000;

pub const Options = struct {
    units: []const []const u8 = &.{},
    user_units: []const []const u8 = &.{},
    follow: bool = false,
    /// Set by `-n` / `--lines`; `-n` without a value means `default_lines`.
    lines: ?Lines = null,
    pager_end: bool = false,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    boot: bool = false,
    /// Boot selector given to `-b` / `--boot`, if any.
    boot_id: ?[]const u8 = null,
    output: Output = .short,
    dmesg: bool = false,
    no_pager: bool = false,
    quiet: bool = false,
    catalog: bool = false,
    no_hostname: bool = false,

    /// Number of trailing lines to show: explicit `-n`, else 1000 for `-e`, else null (no limit).
    pub fn effectiveLines(o: Options) ?Lines {
        if (o.lines) |l| return l;
        if (o.pager_end) return .{ .count = pager_end_lines };
        return null;
    }
};

pub const Request = struct {
    mode: Mode = .run,
    options: Options = .{},
    /// Non-option arguments (journal field matches or paths), raw.
    matches: []const []const u8 = &.{},
};

pub const Result = union(enum) {
    ok: Request,
    err: Failure,
};

const Opt = enum {
    unit,
    user_unit,
    follow,
    lines,
    pager_end,
    since,
    until,
    boot,
    output,
    dmesg,
    no_pager,
    quiet,
    catalog,
    no_hostname,
    version,
    help,

    fn takesValue(opt: Opt) bool {
        return switch (opt) {
            .unit, .user_unit, .since, .until, .output => true,
            else => false,
        };
    }

    /// Value only when attached (`--boot=ID`), or for `-n`/`-b` when the next argument looks like one.
    fn optionalValue(opt: Opt) bool {
        return opt == .lines or opt == .boot;
    }
};

fn longOption(name: []const u8) ?Opt {
    const table = .{
        .{ "unit", Opt.unit },
        .{ "user-unit", Opt.user_unit },
        .{ "follow", Opt.follow },
        .{ "lines", Opt.lines },
        .{ "pager-end", Opt.pager_end },
        .{ "since", Opt.since },
        .{ "until", Opt.until },
        .{ "boot", Opt.boot },
        .{ "output", Opt.output },
        .{ "dmesg", Opt.dmesg },
        .{ "no-pager", Opt.no_pager },
        .{ "quiet", Opt.quiet },
        .{ "catalog", Opt.catalog },
        .{ "no-hostname", Opt.no_hostname },
        .{ "version", Opt.version },
        .{ "help", Opt.help },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn shortOption(c: u8) ?Opt {
    return switch (c) {
        'u' => .unit,
        'f' => .follow,
        'n' => .lines,
        'e' => .pager_end,
        'b' => .boot,
        'o' => .output,
        'k' => .dmesg,
        'q' => .quiet,
        'x' => .catalog,
        'h' => .help,
        else => null,
    };
}

fn isNumber(text: []const u8) bool {
    const digits = std.mem.trimStart(u8, text, "+-");
    if (digits.len == 0 or text.len - digits.len > 1) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn looksLikeLines(text: []const u8) bool {
    return std.mem.eql(u8, text, "all") or (isNumber(text) and text[0] != '-');
}

const Origin = systemctl.Origin;

const State = struct {
    gpa: std.mem.Allocator,
    opts: Options = .{},
    mode: Mode = .run,
    units: std.ArrayList([]const u8) = .empty,
    user_units: std.ArrayList([]const u8) = .empty,
    positional: std.ArrayList([]const u8) = .empty,
    failure: ?Failure = null,

    fn fail(s: *State, kind: Failure.Kind, origin: Origin) !void {
        if (s.failure != null) return;
        const arg = switch (origin) {
            .long => |text| text,
            .short => |c| try std.fmt.allocPrint(s.gpa, "-{c}", .{c}),
        };
        s.failure = .{ .kind = kind, .arg = arg };
    }

    fn apply(s: *State, opt: Opt, value: ?[]const u8, origin: Origin) !void {
        switch (opt) {
            .unit => try s.units.append(s.gpa, value.?),
            .user_unit => try s.user_units.append(s.gpa, value.?),
            .follow => s.opts.follow = true,
            .lines => {
                const v = value orelse {
                    s.opts.lines = .{ .count = default_lines };
                    return;
                };
                if (std.mem.eql(u8, v, "all")) {
                    s.opts.lines = .all;
                } else {
                    const n = std.fmt.parseInt(u32, v, 10) catch return s.fail(.invalid_value, origin);
                    s.opts.lines = .{ .count = n };
                }
            },
            .pager_end => s.opts.pager_end = true,
            .since => s.opts.since = value.?,
            .until => s.opts.until = value.?,
            .boot => {
                s.opts.boot = true;
                s.opts.boot_id = value;
            },
            .output => {
                s.opts.output = std.meta.stringToEnum(Output, value.?) orelse return s.fail(.invalid_value, origin);
            },
            .dmesg => s.opts.dmesg = true,
            .no_pager => s.opts.no_pager = true,
            .quiet => s.opts.quiet = true,
            .catalog => s.opts.catalog = true,
            .no_hostname => s.opts.no_hostname = true,
            .version => s.mode = .version,
            .help => s.mode = .help,
        }
    }

    /// Resolves the value of `opt`: attached text, else the next argument when required (or when
    /// optional and plausible). Returns false when a required value is missing.
    fn takeValue(opt: Opt, attached: ?[]const u8, args: []const []const u8, i: *usize) !?[]const u8 {
        if (attached) |v| return v;
        if (opt.takesValue()) {
            if (i.* + 1 >= args.len) return error.MissingValue;
            i.* += 1;
            return args[i.*];
        }
        if (opt.optionalValue() and i.* + 1 < args.len) {
            const next = args[i.* + 1];
            const plausible = if (opt == .lines) looksLikeLines(next) else isNumber(next) or std.mem.eql(u8, next, "all");
            if (plausible) {
                i.* += 1;
                return next;
            }
        }
        return null;
    }
};

/// Parses `args` (without the program name).
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
            const opt = longOption(name) orelse {
                try s.fail(.unknown_option, .{ .long = shown });
                break;
            };
            const attached: ?[]const u8 = if (eq) |e| body[e + 1 ..] else null;
            if (attached != null and !opt.takesValue() and !opt.optionalValue()) {
                try s.fail(.unexpected_value, .{ .long = shown });
                break;
            }
            const value = State.takeValue(opt, attached, args, &i) catch {
                try s.fail(.missing_value, .{ .long = shown });
                break;
            };
            try s.apply(opt, value, .{ .long = shown });
        } else {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const opt = shortOption(arg[j]) orelse {
                    try s.fail(.unknown_option, .{ .short = arg[j] });
                    break;
                };
                if (!opt.takesValue() and !opt.optionalValue()) {
                    try s.apply(opt, null, .{ .short = arg[j] });
                    continue;
                }
                const attached: ?[]const u8 = if (j + 1 < arg.len) arg[j + 1 ..] else null;
                const value = State.takeValue(opt, attached, args, &i) catch {
                    try s.fail(.missing_value, .{ .short = arg[j] });
                    break;
                };
                try s.apply(opt, value, .{ .short = arg[j] });
                break;
            }
        }
    }
    if (s.failure) |f| return .{ .err = f };
    s.opts.units = try s.units.toOwnedSlice(gpa);
    s.opts.user_units = try s.user_units.toOwnedSlice(gpa);
    return .{ .ok = .{
        .mode = s.mode,
        .options = s.opts,
        .matches = try s.positional.toOwnedSlice(gpa),
    } };
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

test "defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{});
    try testing.expectEqual(Mode.run, r.mode);
    try testing.expect(r.options.effectiveLines() == null);
    try testing.expectEqual(Output.short, r.options.output);
    try testing.expectEqual(@as(usize, 0), r.matches.len);
}

test "repeatable unit options in every form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "-u", "a", "--unit", "b", "--unit=c", "-ud", "--user-unit", "e", "--user-unit=f" });
    try expectStrings(&.{ "a", "b", "c", "d" }, r.options.units);
    try expectStrings(&.{ "e", "f" }, r.options.user_units);
}

test "follow, quiet, catalog, dmesg and formatting flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "-fqxk", "--no-pager", "--no-hostname" });
    const o = r.options;
    try testing.expect(o.follow and o.quiet and o.catalog and o.dmesg and o.no_pager and o.no_hostname);
}

test "lines in every form" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(u32, 5), (try parseOk(a, &.{ "-n", "5" })).options.lines.?.count);
    try testing.expectEqual(@as(u32, 5), (try parseOk(a, &.{"-n5"})).options.lines.?.count);
    try testing.expectEqual(@as(u32, 5), (try parseOk(a, &.{"--lines=5"})).options.lines.?.count);
    try testing.expectEqual(@as(u32, 5), (try parseOk(a, &.{ "--lines", "5" })).options.lines.?.count);
    try testing.expect((try parseOk(a, &.{ "-n", "all" })).options.lines.? == .all);
    try testing.expect((try parseOk(a, &.{"--lines=all"})).options.lines.? == .all);
    try testing.expectEqual(default_lines, (try parseOk(a, &.{"-n"})).options.lines.?.count);
}

test "a bare -n does not swallow a following non-number" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "-n", "_SYSTEMD_UNIT=x.service", "-f" });
    try testing.expectEqual(default_lines, r.options.lines.?.count);
    try expectStrings(&.{"_SYSTEMD_UNIT=x.service"}, r.matches);
    try testing.expect(r.options.follow);
}

test "-e implies 1000 lines unless -n is given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try parseOk(a, &.{"-e"});
    try testing.expect(e.options.pager_end);
    try testing.expectEqual(pager_end_lines, e.options.effectiveLines().?.count);
    const en = try parseOk(a, &.{ "-e", "-n", "3" });
    try testing.expectEqual(@as(u32, 3), en.options.effectiveLines().?.count);
    try testing.expectEqual(@as(u32, 1000), (try parseOk(a, &.{"--pager-end"})).options.effectiveLines().?.count);
}

test "since and until" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), &.{ "--since", "2025-01-01 10:00:00", "--until=yesterday" });
    try testing.expectEqualStrings("2025-01-01 10:00:00", r.options.since.?);
    try testing.expectEqualStrings("yesterday", r.options.until.?);
}

test "boot selector forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b0 = try parseOk(a, &.{"-b"});
    try testing.expect(b0.options.boot and b0.options.boot_id == null);
    const b1 = try parseOk(a, &.{ "-b", "-1" });
    try testing.expectEqualStrings("-1", b1.options.boot_id.?);
    const b2 = try parseOk(a, &.{"--boot=0"});
    try testing.expectEqualStrings("0", b2.options.boot_id.?);
    const b3 = try parseOk(a, &.{ "-b", "-u", "foo" });
    try testing.expect(b3.options.boot and b3.options.boot_id == null);
    try expectStrings(&.{"foo"}, b3.options.units);
}

test "output formats" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Output.cat, (try parseOk(a, &.{ "-o", "cat" })).options.output);
    try testing.expectEqual(Output.cat, (try parseOk(a, &.{"--output=cat"})).options.output);
    try testing.expectEqual(Output.short, (try parseOk(a, &.{"-oshort"})).options.output);
    const f = try parseErr(a, &.{ "-o", "json" });
    try testing.expectEqual(Failure.Kind.invalid_value, f.kind);
    try testing.expectEqualStrings("-o", f.arg);
}

test "errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f1 = try parseErr(a, &.{"-u"});
    try testing.expectEqual(Failure.Kind.missing_value, f1.kind);
    try testing.expectEqualStrings("-u", f1.arg);
    const f2 = try parseErr(a, &.{"--since"});
    try testing.expectEqual(Failure.Kind.missing_value, f2.kind);
    const f3 = try parseErr(a, &.{"--bogus"});
    try testing.expectEqual(Failure.Kind.unknown_option, f3.kind);
    const f4 = try parseErr(a, &.{"--follow=1"});
    try testing.expectEqual(Failure.Kind.unexpected_value, f4.kind);
    const f5 = try parseErr(a, &.{"--lines=many"});
    try testing.expectEqual(Failure.Kind.invalid_value, f5.kind);
    const f6 = try parseErr(a, &.{"-fZ"});
    try testing.expectEqualStrings("-Z", f6.arg);
}

test "matches, terminator, help and version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseOk(a, &.{ "_PID=1", "-f", "--", "-u", "/dev/null" });
    try expectStrings(&.{ "_PID=1", "-u", "/dev/null" }, r.matches);
    try testing.expect(r.options.follow);
    try testing.expectEqual(Mode.version, (try parseOk(a, &.{"--version"})).mode);
    try testing.expectEqual(Mode.help, (try parseOk(a, &.{"-h"})).mode);
}
