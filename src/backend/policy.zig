//! Hybrid generation rule (§6.7): decides whether a unit can run as a plain native command or
//! needs `fake-systemd --exec <unit>`. Pure functions over the unit model.
const std = @import("std");
const model = @import("../unit/model.zig");
const interface = @import("interface.zig");

/// Location of the executor binary written into generated files; the only place it is defined.
pub const executor_path = "/usr/bin/fake-systemd";

/// Settings the target format expresses without the executor, beyond the common baseline
/// (`User=` alone, an absolute `WorkingDirectory=`, `Nice=`, `NoNewPrivileges=`, `KillSignal=`).
pub const Native = struct {
    /// `Type=forking` with `PIDFile=` is supervised by the init itself.
    forking_pidfile: bool = false,
    /// `Type=forking` without `PIDFile=` runs as a command that is not supervised.
    forking_plain: bool = false,
    /// `Environment=` is applied by an `env` wrapper in the command.
    environment: bool = false,
    /// Resource limit names (`LimitNOFILE` form) the format sets with plain numbers or `infinity`.
    limits: []const []const u8 = &.{},
};

/// First reason that forces the executor; `null` means the native command is enough.
pub const Reason = enum {
    exec_start_pre,
    exec_start_post,
    environment_file,
    environment,
    unset_environment,
    variable_expansion,
    unrepresentable_word,
    runtime_directories,
    forking,
    oneshot,
    privileged_prefix,
    argv0_prefix,
    ignored_failure,
    several_commands,
    limits,
    umask,
    group,
    working_directory,
    no_command,

    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .exec_start_pre => "ExecStartPre=",
            .exec_start_post => "ExecStartPost=",
            .environment_file => "EnvironmentFile=",
            .environment => "Environment=",
            .unset_environment => "UnsetEnvironment=",
            .variable_expansion => "variable expansion in a command",
            .unrepresentable_word => "a command word the native format cannot hold",
            .runtime_directories => "RuntimeDirectory= and related directories",
            .forking => "Type=forking",
            .oneshot => "Type=oneshot",
            .privileged_prefix => "command prefix +, ! or !!",
            .argv0_prefix => "command prefix @",
            .ignored_failure => "command prefix - on a oneshot",
            .several_commands => "several ExecStart= commands",
            .limits => "Limit*=",
            .umask => "UMask=",
            .group => "Group= or SupplementaryGroups=",
            .working_directory => "WorkingDirectory= with ~ or -",
            .no_command => "no ExecStart=",
        };
    }
};

fn expansionFree(word: []const u8) ?bool {
    var i: usize = 0;
    while (i < word.len) : (i += 1) {
        switch (word[i]) {
            '$' => {
                if (i + 1 < word.len and word[i + 1] == '$') {
                    i += 1;
                } else return false;
            },
            '\n', '\r', 0 => return null,
            else => {},
        }
    }
    return true;
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

/// `infinity` or digits, optionally `soft:hard`.
pub fn plainLimit(value: []const u8) bool {
    var it = std.mem.splitScalar(u8, value, ':');
    var parts: usize = 0;
    while (it.next()) |p| : (parts += 1) {
        if (parts > 1 or p.len == 0) return false;
        if (std.mem.eql(u8, p, "infinity")) continue;
        for (p) |c| if (!std.ascii.isDigit(c)) return false;
    }
    return parts >= 1;
}

fn commandReason(c: model.Command, oneshot: bool) ?Reason {
    if (c.flags.plus or c.flags.bang or c.flags.bang_bang) return .privileged_prefix;
    if (c.flags.argv0) return .argv0_prefix;
    if (c.flags.ignore_failure and oneshot) return .ignored_failure;
    for (c.words) |w| {
        const ok = expansionFree(w) orelse return .unrepresentable_word;
        if (!ok) return .variable_expansion;
    }
    return null;
}

fn hasDirectories(u: model.Unit) bool {
    return u.runtime_directory.len + u.state_directory.len + u.cache_directory.len +
        u.logs_directory.len + u.configuration_directory.len > 0;
}

fn workingDirectoryPlain(path: []const u8) bool {
    return path.len > 0 and path[0] == '/' and (expansionFree(path) orelse false);
}

pub fn executorReason(unit: model.Unit, caps: interface.Capabilities, native: Native) ?Reason {
    if (unit.exec_start.len == 0) return .no_command;
    const oneshot = unit.service_type == .oneshot;
    if (unit.exec_start_pre.len > 0) return .exec_start_pre;
    if (unit.exec_start_post.len > 0) return .exec_start_post;
    if (unit.environment_file.len > 0) return .environment_file;
    if (unit.unset_environment.len > 0) return .unset_environment;
    if (unit.environment.len > 0 and !native.environment) return .environment;
    if (hasDirectories(unit)) return .runtime_directories;
    if (unit.service_type == .forking) {
        const supervised = if (unit.pid_file != null) native.forking_pidfile else native.forking_plain;
        if (!supervised and caps.supervision) return .forking;
    }
    if (oneshot and !caps.oneshot) return .oneshot;
    if (unit.umask != null) return .umask;
    if (unit.group != null or unit.supplementary_groups.len > 0) return .group;
    if (unit.working_directory) |w| {
        if (!workingDirectoryPlain(w)) return .working_directory;
    }
    for (unit.limits) |l| {
        if (!inList(native.limits, l.key) or !plainLimit(l.value)) return .limits;
    }
    if (unit.exec_start.len > 1) return .several_commands;
    for (unit.exec_start) |c| if (commandReason(c, oneshot)) |r| return r;
    return null;
}

/// True when the generic hybrid rule (§6.7) sends the unit through the executor.
pub fn needsExecutor(unit: model.Unit, caps: interface.Capabilities) bool {
    return executorReason(unit, caps, .{}) != null;
}

/// Same as `needsExecutor` for a format that expresses the settings listed in `native`.
pub fn needsExecutorWith(unit: model.Unit, caps: interface.Capabilities, native: Native) bool {
    return executorReason(unit, caps, native) != null;
}

/// True when `ExecStop=` or `ExecStopPost=` has to run through the executor.
pub fn needsStopHook(unit: model.Unit) bool {
    return unit.exec_stop.len > 0 or unit.exec_stop_post.len > 0;
}

/// True when a single `ExecStop=` command can be the init's own stop command: a oneshot, whose
/// stop has no process to signal, with a command free of prefixes and expansion.
pub fn plainStopCommand(unit: model.Unit) bool {
    if (unit.service_type != .oneshot or unit.exec_stop.len != 1 or unit.exec_stop_post.len > 0) return false;
    return commandReason(unit.exec_stop[0], false) == null and !unit.exec_stop[0].flags.ignore_failure;
}

const testing = std.testing;
const execline = @import("../unit/execline.zig");

const all_caps: interface.Capabilities = .{ .supervision = true, .oneshot = true, .restart_policy = true };

fn cmds(a: std.mem.Allocator, text: []const u8) ![]const model.Command {
    return execline.parseAll(a, text);
}

fn base(a: std.mem.Allocator) !model.Unit {
    return .{
        .name = try @import("../unit/name.zig").parse(a, "foo.service"),
        .scope = .system,
        .exec_start = try cmds(a, "/usr/bin/foo --daemon"),
    };
}

test "a plain command stays native" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var u = try base(arena.allocator());
    try testing.expect(!needsExecutor(u, all_caps));
    u.user = "svc";
    u.working_directory = "/var/lib/foo";
    u.nice = 5;
    u.restart = .always;
    u.kill_signal = "SIGINT";
    try testing.expect(!needsExecutor(u, all_caps));
}

test "each trigger of the spec list forces the executor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { reason: Reason, edit: *const fn (std.mem.Allocator, *model.Unit) anyerror!void }{
        .{ .reason = .exec_start_pre, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start_pre = try cmds(al, "/bin/prep");
            }
        }.f },
        .{ .reason = .exec_start_post, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start_post = try cmds(al, "/bin/after");
            }
        }.f },
        .{ .reason = .environment_file, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.environment_file = &.{.{ .path = "/etc/default/foo", .optional = true }};
            }
        }.f },
        .{ .reason = .environment, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.environment = &.{.{ .name = "A", .value = "1" }};
            }
        }.f },
        .{ .reason = .unset_environment, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.unset_environment = &.{"A"};
            }
        }.f },
        .{ .reason = .variable_expansion, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start = try cmds(al, "/usr/bin/foo $OPTS");
            }
        }.f },
        .{ .reason = .variable_expansion, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start = try cmds(al, "/usr/bin/foo ${OPTS}");
            }
        }.f },
        .{ .reason = .runtime_directories, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.runtime_directory = &.{"foo"};
            }
        }.f },
        .{ .reason = .runtime_directories, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.state_directory = &.{"foo"};
            }
        }.f },
        .{ .reason = .forking, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.service_type = .forking;
            }
        }.f },
        .{ .reason = .privileged_prefix, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start = try cmds(al, "+/usr/bin/foo");
            }
        }.f },
        .{ .reason = .privileged_prefix, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start = try cmds(al, "!!/usr/bin/foo");
            }
        }.f },
        .{ .reason = .argv0_prefix, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start = try cmds(al, "@/usr/bin/foo foo-name");
            }
        }.f },
        .{ .reason = .limits, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.limits = &.{.{ .key = "LimitNOFILE", .value = "4096" }};
            }
        }.f },
        .{ .reason = .umask, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.umask = 0o027;
            }
        }.f },
        .{ .reason = .group, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.group = "svc";
            }
        }.f },
        .{ .reason = .group, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.supplementary_groups = &.{"audio"};
            }
        }.f },
        .{ .reason = .working_directory, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.working_directory = "~";
            }
        }.f },
        .{ .reason = .working_directory, .edit = struct {
            fn f(_: std.mem.Allocator, u: *model.Unit) !void {
                u.working_directory = "-/srv/foo";
            }
        }.f },
        .{ .reason = .several_commands, .edit = struct {
            fn f(al: std.mem.Allocator, u: *model.Unit) !void {
                u.exec_start = try cmds(al, "/bin/a ; /bin/b");
            }
        }.f },
    };
    for (cases) |c| {
        var u = try base(a);
        try c.edit(a, &u);
        try testing.expectEqual(@as(?Reason, c.reason), executorReason(u, all_caps, .{}));
        try testing.expect(needsExecutor(u, all_caps));
    }
}

test "literal dollar signs and plain prefixes are native" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try base(a);
    u.exec_start = try cmds(a, "/usr/bin/foo --price=$$5");
    try testing.expect(!needsExecutor(u, all_caps));
    u.exec_start = try cmds(a, "/usr/bin/foo cost $ 5");
    try testing.expectEqual(@as(?Reason, .variable_expansion), executorReason(u, all_caps, .{}));
    u.exec_start = try cmds(a, "-/usr/bin/foo");
    try testing.expect(!needsExecutor(u, all_caps));
    u.service_type = .oneshot;
    try testing.expectEqual(@as(?Reason, .ignored_failure), executorReason(u, all_caps, .{}));
}

test "native support lifts the corresponding triggers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const native: Native = .{ .forking_pidfile = true, .environment = true, .limits = &.{ "LimitNOFILE", "LimitCORE" } };
    var u = try base(a);
    u.service_type = .forking;
    try testing.expect(needsExecutorWith(u, all_caps, native));
    u.pid_file = "/run/foo.pid";
    try testing.expect(!needsExecutorWith(u, all_caps, native));
    try testing.expect(needsExecutor(u, all_caps));
    u.environment = &.{.{ .name = "A", .value = "x y" }};
    try testing.expect(!needsExecutorWith(u, all_caps, native));
    u.limits = &.{ .{ .key = "LimitNOFILE", .value = "1024:infinity" }, .{ .key = "LimitCORE", .value = "infinity" } };
    try testing.expect(!needsExecutorWith(u, all_caps, native));
    u.limits = &.{.{ .key = "LimitNPROC", .value = "10" }};
    try testing.expectEqual(@as(?Reason, .limits), executorReason(u, all_caps, native));
    u.limits = &.{.{ .key = "LimitNOFILE", .value = "2G" }};
    try testing.expectEqual(@as(?Reason, .limits), executorReason(u, all_caps, native));
}

test "capabilities decide on supervision and oneshot" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var u = try base(arena.allocator());
    u.service_type = .forking;
    try testing.expect(!needsExecutor(u, .{}));
    u.service_type = .oneshot;
    try testing.expectEqual(@as(?Reason, .oneshot), executorReason(u, .{}, .{}));
    try testing.expect(!needsExecutor(u, all_caps));
}

test "a unit without ExecStart= has no native command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var u = try base(arena.allocator());
    u.exec_start = &.{};
    try testing.expectEqual(@as(?Reason, .no_command), executorReason(u, all_caps, .{}));
}

test "stop hooks and plain stop commands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var u = try base(a);
    try testing.expect(!needsStopHook(u));
    u.exec_stop = try cmds(a, "/usr/bin/foo-ctl stop");
    try testing.expect(needsStopHook(u));
    try testing.expect(!plainStopCommand(u));
    u.service_type = .oneshot;
    try testing.expect(plainStopCommand(u));
    u.exec_stop = try cmds(a, "-/usr/bin/foo-ctl stop");
    try testing.expect(!plainStopCommand(u));
    u.exec_stop = try cmds(a, "/usr/bin/foo-ctl $ARG");
    try testing.expect(!plainStopCommand(u));
    u.exec_stop = try cmds(a, "/usr/bin/foo-ctl stop");
    u.exec_stop_post = try cmds(a, "/bin/cleanup");
    try testing.expect(!plainStopCommand(u));
}

test "plain limit values" {
    try testing.expect(plainLimit("1024"));
    try testing.expect(plainLimit("infinity"));
    try testing.expect(plainLimit("1024:infinity"));
    try testing.expect(!plainLimit("1G"));
    try testing.expect(!plainLimit("1:2:3"));
    try testing.expect(!plainLimit(":2"));
    try testing.expect(!plainLimit(""));
}
