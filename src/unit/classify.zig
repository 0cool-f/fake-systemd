//! Classifier (§6.2): decides from the unit content and injected facts whether a unit is a
//! service to translate. Pure: no filesystem or configuration access.
const std = @import("std");
const model = @import("model.zig");
const name_mod = @import("name.zig");

pub const Kind = enum {
    /// Translated on `enable` and `start`.
    candidate,
    /// No `[Install]`: translated only on `start` or as a dependency.
    static,
    unsupported,
    /// Service started by a `.timer`; handled by the timer subsystem.
    timer_service,
    /// Started only by a socket, path or D-Bus request: unsupported, reported with a notice.
    activation_only,
};

pub const Rule = enum {
    denied,
    allowed,
    unit_type,
    systemd_unit,
    lifecycle_target,
    boot_shutdown_hook,
    systemd_condition,
    missing_executable,
    no_exec_start,
    activation_only,
    timer_triggered,
    no_install,
    ordinary,
};

pub const Classification = struct {
    kind: Kind,
    rule: Rule,
    /// One line explaining the rule, suitable for `status`.
    reason: []const u8,

    /// True when the outcome deserves a `notice` when first met.
    pub fn needsNotice(c: Classification) bool {
        return c.kind == .activation_only;
    }
};

pub const Facts = struct {
    context: ?*const anyopaque = null,
    /// Whether an absolute path names an executable file.
    executable_exists: *const fn (context: ?*const anyopaque, path: []const u8) bool,
    /// Whether a `.timer` refers to the unit with this full name.
    is_timer_triggered: *const fn (context: ?*const anyopaque, name: []const u8) bool,
    /// Whether a `.socket` or `.path` unit activates the unit with this full name.
    has_socket_or_path_activator: *const fn (context: ?*const anyopaque, name: []const u8) bool = noActivator,
    /// The backend declares an equivalent of boot/shutdown hooks (§11.1).
    backend_has_shutdown_hooks: bool = false,
    /// `[Classify] Allow=` and `Deny=` glob lists.
    allow: []const []const u8 = &.{},
    deny: []const []const u8 = &.{},
};

fn noActivator(_: ?*const anyopaque, _: []const u8) bool {
    return false;
}

const exec_search_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };

pub fn classify(unit: model.Unit, facts: Facts) Classification {
    const name = unit.name;
    if (matchesAny(facts.deny, name)) return result(.unsupported, .denied);
    if (name.kind != .service and name.kind != .timer) return result(.unsupported, .unit_type);
    if (matchesAny(facts.allow, name)) return result(.candidate, .allowed);
    if (std.mem.startsWith(u8, name.base(), "systemd-")) return result(.unsupported, .systemd_unit);
    if (onlyLifecycleTargets(unit)) return result(.unsupported, .lifecycle_target);
    if (isBootShutdownHook(unit) and !facts.backend_has_shutdown_hooks) {
        return result(.unsupported, .boot_shutdown_hook);
    }
    if (conditionsExcludeUnit(unit.conditions)) return result(.unsupported, .systemd_condition);
    if (name.kind == .service) {
        if (checkExec(unit, facts)) |rule| return result(.unsupported, rule);
        if (!unit.has_install and isActivationOnly(unit, facts)) return result(.activation_only, .activation_only);
        if (facts.is_timer_triggered(facts.context, name.full)) return result(.timer_service, .timer_triggered);
    }
    if (!unit.has_install) return result(.static, .no_install);
    return result(.candidate, .ordinary);
}

fn result(kind: Kind, rule: Rule) Classification {
    return .{ .kind = kind, .rule = rule, .reason = reason(rule) };
}

pub fn reason(rule: Rule) []const u8 {
    return switch (rule) {
        .denied => "excluded by Deny= in the fake-systemd configuration",
        .allowed => "translation forced by Allow= in the fake-systemd configuration",
        .unit_type => "unit type is not translated",
        .systemd_unit => "provided by systemd itself",
        .lifecycle_target => "system lifecycle hook, wanted only by shutdown, sleep, rescue or initrd targets",
        .boot_shutdown_hook => "boot or shutdown hook: DefaultDependencies=no, Type=oneshot, ordered around shutdown.target",
        .systemd_condition => "depends on a condition specific to systemd",
        .missing_executable => "the ExecStart executable does not exist",
        .no_exec_start => "no ExecStart= is defined",
        .activation_only => "activated only by a socket, path or D-Bus request",
        .timer_triggered => "started by a timer, handled by the timer subsystem",
        .no_install => "no [Install] section, translated only when started or required",
        .ordinary => "ordinary service",
    };
}

fn matchesAny(globs: []const []const u8, name: name_mod.Name) bool {
    const short = if (name.kind == .service) name.base() else name.full;
    for (globs) |g| {
        if (name_mod.globMatch(g, name.full) or name_mod.globMatch(g, short)) return true;
    }
    return false;
}

fn isLifecycleTarget(unit_name: []const u8) bool {
    const suffix = ".target";
    if (!std.mem.endsWith(u8, unit_name, suffix)) return false;
    const stem = unit_name[0 .. unit_name.len - suffix.len];
    const exact = [_][]const u8{
        "shutdown", "reboot",    "halt",         "poweroff",  "kexec",  "final", "sleep",
        "suspend",  "hibernate", "hybrid-sleep", "emergency", "rescue",
    };
    for (exact) |e| if (std.mem.eql(u8, stem, e)) return true;
    return std.mem.startsWith(u8, stem, "initrd");
}

fn onlyLifecycleTargets(unit: model.Unit) bool {
    if (unit.wanted_by.len + unit.required_by.len == 0) return false;
    for (unit.wanted_by) |t| if (!isLifecycleTarget(t)) return false;
    for (unit.required_by) |t| if (!isLifecycleTarget(t)) return false;
    return true;
}

fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn isBootShutdownHook(unit: model.Unit) bool {
    if (unit.default_dependencies or unit.service_type != .oneshot) return false;
    return contains(unit.before, "shutdown.target") or contains(unit.conflicts, "shutdown.target");
}

const ConditionKind = enum { condition, assertion };

const ParsedCondition = struct {
    kind: ConditionKind,
    trigger: bool,
    negated: bool,
    /// True when the check can only be evaluated by systemd.
    systemd_only: bool,
};

fn parseCondition(c: model.Directive) ?ParsedCondition {
    var kind: ConditionKind = .condition;
    var stem: []const u8 = undefined;
    if (std.mem.startsWith(u8, c.key, "Condition")) {
        stem = c.key["Condition".len..];
    } else if (std.mem.startsWith(u8, c.key, "Assert")) {
        kind = .assertion;
        stem = c.key["Assert".len..];
    } else return null;
    var value = c.value;
    const trigger = std.mem.startsWith(u8, value, "|");
    if (trigger) value = value[1..];
    const negated = std.mem.startsWith(u8, value, "!");
    if (negated) value = value[1..];
    return .{ .kind = kind, .trigger = trigger, .negated = negated, .systemd_only = isSystemdOnly(stem, value) };
}

fn isSystemdOnly(stem: []const u8, value: []const u8) bool {
    const path_keys = [_][]const u8{
        "PathExists",      "PathExistsGlob",  "PathIsDirectory",   "PathIsSymbolicLink", "PathIsMountPoint",
        "PathIsReadWrite", "PathIsEncrypted", "DirectoryNotEmpty", "FileNotEmpty",       "FileIsExecutable",
    };
    for (path_keys) |k| {
        if (std.mem.eql(u8, stem, k)) {
            return std.mem.startsWith(u8, value, "/run/systemd/") or std.mem.eql(u8, value, "/run/systemd");
        }
    }
    const state_keys = [_][]const u8{ "ControlGroupController", "FirstBoot", "NeedsUpdate" };
    for (state_keys) |k| if (std.mem.eql(u8, stem, k)) return true;
    if (std.mem.eql(u8, stem, "Virtualization")) return std.mem.eql(u8, value, "systemd-nspawn");
    return false;
}

/// A negated systemd-only check holds on a system without systemd, so it never excludes the unit.
/// Non-trigger checks must all hold; trigger checks of one kind need at least one to hold.
fn conditionsExcludeUnit(conditions: []const model.Directive) bool {
    var trigger_total = [_]usize{ 0, 0 };
    var trigger_failing = [_]usize{ 0, 0 };
    for (conditions) |c| {
        const p = parseCondition(c) orelse continue;
        const fails = p.systemd_only and !p.negated;
        if (!p.trigger) {
            if (fails) return true;
            continue;
        }
        trigger_total[@backingInt(p.kind)] += 1;
        if (fails) trigger_failing[@backingInt(p.kind)] += 1;
    }
    for (trigger_total, trigger_failing) |total, failing| {
        if (total > 0 and total == failing) return true;
    }
    return false;
}

fn executableFound(facts: Facts, exe: []const u8) bool {
    if (exe.len == 0 or exe[0] == '$') return false;
    if (exe[0] == '/') return facts.executable_exists(facts.context, exe);
    if (std.mem.findScalar(u8, exe, '/') != null) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (exec_search_dirs) |dir| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, exe }) catch return false;
        if (facts.executable_exists(facts.context, path)) return true;
    }
    return false;
}

fn checkExec(unit: model.Unit, facts: Facts) ?Rule {
    if (unit.exec_start.len == 0) {
        return if (unit.service_type == .oneshot) null else .no_exec_start;
    }
    for (unit.exec_start) |cmd| {
        if (cmd.flags.ignore_failure) continue;
        if (!executableFound(facts, cmd.executable())) return .missing_executable;
    }
    return null;
}

fn isActivationOnly(unit: model.Unit, facts: Facts) bool {
    if (unit.service_type == .dbus and unit.bus_name != null) return true;
    return facts.has_socket_or_path_activator(facts.context, unit.name.full);
}

const testing = std.testing;

const Fixture = struct {
    executables: []const []const u8 = &.{ "/usr/bin/foo", "/usr/bin/true" },
    timer_targets: []const []const u8 = &.{},
    activated: []const []const u8 = &.{},

    fn facts(f: *const Fixture) Facts {
        return .{
            .context = f,
            .executable_exists = exeExists,
            .is_timer_triggered = timerTriggered,
            .has_socket_or_path_activator = hasActivator,
        };
    }

    fn self(ctx: ?*const anyopaque) *const Fixture {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn exeExists(ctx: ?*const anyopaque, path: []const u8) bool {
        return contains(self(ctx).executables, path);
    }

    fn timerTriggered(ctx: ?*const anyopaque, name: []const u8) bool {
        return contains(self(ctx).timer_targets, name);
    }

    fn hasActivator(ctx: ?*const anyopaque, name: []const u8) bool {
        return contains(self(ctx).activated, name);
    }
};

fn unitFor(arena: std.mem.Allocator, unit_name: []const u8) !model.Unit {
    var u: model.Unit = .{ .name = try name_mod.parse(arena, unit_name), .scope = .system };
    if (u.name.kind == .service) u.exec_start = try commands(arena, &.{"/usr/bin/foo --run"});
    u.has_install = true;
    u.wanted_by = &.{"multi-user.target"};
    return u;
}

fn commands(arena: std.mem.Allocator, lines: []const []const u8) ![]const model.Command {
    var out: std.ArrayList(model.Command) = .empty;
    for (lines) |l| try out.appendSlice(arena, try @import("execline.zig").parseAll(arena, l));
    return out.toOwnedSlice(arena);
}

fn expectClass(expected_kind: Kind, expected_rule: Rule, c: Classification) !void {
    try testing.expectEqual(expected_kind, c.kind);
    try testing.expectEqual(expected_rule, c.rule);
    try testing.expect(c.reason.len > 0);
}

test "row: ordinary service is a candidate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    const u = try unitFor(arena.allocator(), "foo");
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
}

test "row: unit types that are never translated" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    const types = [_][]const u8{
        "a.mount", "a.automount", "a.swap", "a.device", "a.slice", "a.scope", "a.target", "a.socket", "a.path",
    };
    for (types) |t| {
        const u = try unitFor(arena.allocator(), t);
        try expectClass(.unsupported, .unit_type, classify(u, fx.facts()));
    }
}

test "row: systemd-provided units" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    for ([_][]const u8{ "systemd-journald", "systemd-logind.service", "systemd-tmpfiles-clean.timer" }) |n| {
        const u = try unitFor(arena.allocator(), n);
        try expectClass(.unsupported, .systemd_unit, classify(u, fx.facts()));
    }
    const near = try unitFor(arena.allocator(), "systemdx");
    try expectClass(.candidate, .ordinary, classify(near, fx.facts()));
}

test "row: lifecycle targets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    const targets = [_][]const u8{
        "shutdown.target", "reboot.target",             "halt.target",      "poweroff.target",  "kexec.target",
        "final.target",    "sleep.target",              "suspend.target",   "hibernate.target", "hybrid-sleep.target",
        "initrd.target",   "initrd-switch-root.target", "emergency.target", "rescue.target",
    };
    for (targets) |t| {
        var u = try unitFor(arena.allocator(), "foo");
        u.wanted_by = &.{t};
        try expectClass(.unsupported, .lifecycle_target, classify(u, fx.facts()));
    }
    var u = try unitFor(arena.allocator(), "foo");
    u.wanted_by = &.{ "shutdown.target", "reboot.target" };
    u.required_by = &.{"halt.target"};
    try expectClass(.unsupported, .lifecycle_target, classify(u, fx.facts()));
}

test "row: mixed lifecycle and regular targets stay candidates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var u = try unitFor(arena.allocator(), "foo");
    u.wanted_by = &.{ "shutdown.target", "multi-user.target" };
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    u.wanted_by = &.{"shutdown.service"};
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
}

test "row: boot/shutdown hook" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var u = try unitFor(arena.allocator(), "foo");
    u.default_dependencies = false;
    u.service_type = .oneshot;
    u.before = &.{"shutdown.target"};
    try expectClass(.unsupported, .boot_shutdown_hook, classify(u, fx.facts()));
    u.before = &.{};
    u.conflicts = &.{"shutdown.target"};
    try expectClass(.unsupported, .boot_shutdown_hook, classify(u, fx.facts()));
    var facts = fx.facts();
    facts.backend_has_shutdown_hooks = true;
    try expectClass(.candidate, .ordinary, classify(u, facts));
    u.service_type = .simple;
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    u.service_type = .oneshot;
    u.default_dependencies = true;
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    u.default_dependencies = false;
    u.conflicts = &.{};
    u.before = &.{"network.target"};
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
}

test "row: systemd-specific conditions and assertions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    const specific = [_]model.Directive{
        .{ .key = "ConditionPathExists", .value = "/run/systemd/system" },
        .{ .key = "AssertPathExists", .value = "/run/systemd/notify" },
        .{ .key = "ConditionVirtualization", .value = "systemd-nspawn" },
        .{ .key = "ConditionFirstBoot", .value = "yes" },
        .{ .key = "ConditionNeedsUpdate", .value = "/etc" },
        .{ .key = "ConditionControlGroupController", .value = "cpu" },
    };
    for (specific) |c| {
        var u = try unitFor(arena.allocator(), "foo");
        u.conditions = &.{c};
        try expectClass(.unsupported, .systemd_condition, classify(u, fx.facts()));
    }
    const harmless = [_]model.Directive{
        .{ .key = "ConditionPathExists", .value = "/etc/foo.conf" },
        .{ .key = "ConditionPathExists", .value = "/run/systemdish" },
        .{ .key = "ConditionVirtualization", .value = "!container" },
        .{ .key = "ConditionHost", .value = "box" },
        .{ .key = "ConditionACPower", .value = "true" },
        .{ .key = "ConditionPathIsDirectory", .value = "!/run/systemd/resolve" },
        .{ .key = "ConditionVirtualization", .value = "!systemd-nspawn" },
        .{ .key = "ConditionFirstBoot", .value = "|!yes" },
    };
    for (harmless) |c| {
        var u = try unitFor(arena.allocator(), "foo");
        u.conditions = &.{c};
        try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    }
}

test "trigger conditions exclude the unit only when every alternative is a non-negated systemd-only one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    const cases = [_]struct { []const model.Directive, Kind }{
        .{ &.{.{ .key = "ConditionPathExists", .value = "|/run/systemd/system" }}, .unsupported },
        .{ &.{
            .{ .key = "ConditionPathExists", .value = "|/run/systemd/system" },
            .{ .key = "ConditionFirstBoot", .value = "|yes" },
        }, .unsupported },
        .{ &.{
            .{ .key = "ConditionPathExists", .value = "|/run/systemd/system" },
            .{ .key = "ConditionPathExists", .value = "|/etc/foo" },
        }, .candidate },
        .{ &.{
            .{ .key = "ConditionPathExists", .value = "|/run/systemd/system" },
            .{ .key = "ConditionPathExists", .value = "|!/run/systemd/system" },
        }, .candidate },
        .{ &.{
            .{ .key = "ConditionPathExists", .value = "|/run/systemd/system" },
            .{ .key = "AssertPathExists", .value = "|/etc/foo" },
        }, .unsupported },
        .{ &.{
            .{ .key = "ConditionPathExists", .value = "|/run/systemd/system" },
            .{ .key = "ConditionHost", .value = "box" },
        }, .unsupported },
        .{ &.{
            .{ .key = "ConditionPathExists", .value = "!/run/systemd/system" },
            .{ .key = "ConditionPathExists", .value = "/run/systemd/system" },
        }, .unsupported },
    };
    for (cases) |case| {
        var u = try unitFor(arena.allocator(), "foo");
        u.conditions = case[0];
        try testing.expectEqual(case[1], classify(u, fx.facts()).kind);
    }
}

test "row: missing ExecStart executable" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fx: Fixture = .{};
    var u = try unitFor(a, "foo");
    u.exec_start = try commands(a, &.{"/usr/bin/missing -x"});
    try expectClass(.unsupported, .missing_executable, classify(u, fx.facts()));
    u.exec_start = try commands(a, &.{"-/usr/bin/missing"});
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    u.exec_start = try commands(a, &.{ "/usr/bin/foo", "/usr/bin/missing" });
    try expectClass(.unsupported, .missing_executable, classify(u, fx.facts()));
    u.exec_start = try commands(a, &.{"$BIN --x"});
    try expectClass(.unsupported, .missing_executable, classify(u, fx.facts()));
    u.exec_start = try commands(a, &.{"sub/dir/foo"});
    try expectClass(.unsupported, .missing_executable, classify(u, fx.facts()));
}

test "bare executable names are searched in the standard directories" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx: Fixture = .{ .executables = &.{"/bin/tool"} };
    var u = try unitFor(a, "foo");
    u.exec_start = try commands(a, &.{"tool --x"});
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    fx.executables = &.{"/usr/local/bin/tool"};
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
    fx.executables = &.{"/opt/tool"};
    try expectClass(.unsupported, .missing_executable, classify(u, fx.facts()));
}

test "missing ExecStart: error for most types, fine for oneshot" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var u = try unitFor(arena.allocator(), "foo");
    u.exec_start = &.{};
    try expectClass(.unsupported, .no_exec_start, classify(u, fx.facts()));
    u.service_type = .oneshot;
    u.remain_after_exit = true;
    try expectClass(.candidate, .ordinary, classify(u, fx.facts()));
}

test "row: activated only by socket, path or D-Bus" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{ .activated = &.{"sock.service"} };
    var dbus = try unitFor(arena.allocator(), "dbus-thing");
    dbus.service_type = .dbus;
    dbus.bus_name = "org.example.Thing";
    dbus.has_install = false;
    dbus.wanted_by = &.{};
    const c = classify(dbus, fx.facts());
    try expectClass(.activation_only, .activation_only, c);
    try testing.expect(c.needsNotice());
    var sock = try unitFor(arena.allocator(), "sock");
    sock.has_install = false;
    sock.wanted_by = &.{};
    try expectClass(.activation_only, .activation_only, classify(sock, fx.facts()));
    sock.has_install = true;
    try expectClass(.candidate, .ordinary, classify(sock, fx.facts()));
    dbus.has_install = true;
    try expectClass(.candidate, .ordinary, classify(dbus, fx.facts()));
    var dbus_no_name = try unitFor(arena.allocator(), "dbus2");
    dbus_no_name.service_type = .dbus;
    dbus_no_name.has_install = false;
    try expectClass(.static, .no_install, classify(dbus_no_name, fx.facts()));
}

test "row: service referenced by a timer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{ .timer_targets = &.{"backup.service"} };
    var u = try unitFor(arena.allocator(), "backup");
    u.has_install = false;
    u.wanted_by = &.{};
    const c = classify(u, fx.facts());
    try expectClass(.timer_service, .timer_triggered, c);
    try testing.expect(!c.needsNotice());
    u.has_install = true;
    try expectClass(.timer_service, .timer_triggered, classify(u, fx.facts()));
}

test "row: no [Install] section is static" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var u = try unitFor(arena.allocator(), "foo");
    u.has_install = false;
    u.wanted_by = &.{};
    try expectClass(.static, .no_install, classify(u, fx.facts()));
}

test "timer units skip service-only rules" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var t = try unitFor(arena.allocator(), "backup.timer");
    t.wanted_by = &.{"timers.target"};
    try expectClass(.candidate, .ordinary, classify(t, fx.facts()));
    t.has_install = false;
    try expectClass(.static, .no_install, classify(t, fx.facts()));
}

test "Deny wins over everything, Allow forces translation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fx: Fixture = .{};
    var facts = fx.facts();
    facts.deny = &.{ "foo", "bar-*" };
    try expectClass(.unsupported, .denied, classify(try unitFor(a, "foo"), facts));
    try expectClass(.unsupported, .denied, classify(try unitFor(a, "foo.service"), facts));
    try expectClass(.unsupported, .denied, classify(try unitFor(a, "bar-baz"), facts));
    try expectClass(.candidate, .ordinary, classify(try unitFor(a, "other"), facts));

    facts = fx.facts();
    facts.allow = &.{ "systemd-resolved", "gone", "x.service", "scheduled*" };
    try expectClass(.candidate, .allowed, classify(try unitFor(a, "systemd-resolved"), facts));
    var gone = try unitFor(a, "gone");
    gone.exec_start = try commands(a, &.{"/usr/bin/missing"});
    try expectClass(.candidate, .allowed, classify(gone, facts));
    try expectClass(.candidate, .allowed, classify(try unitFor(a, "x"), facts));
    try expectClass(.candidate, .allowed, classify(try unitFor(a, "scheduled.timer"), facts));
    var hook = try unitFor(a, "scheduled-hook");
    hook.wanted_by = &.{"shutdown.target"};
    try expectClass(.candidate, .allowed, classify(hook, facts));

    facts.deny = &.{"gone"};
    try expectClass(.unsupported, .denied, classify(gone, facts));
}

test "Allow does not translate unit types without a model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var facts = fx.facts();
    facts.allow = &.{"*"};
    try expectClass(.unsupported, .unit_type, classify(try unitFor(arena.allocator(), "a.mount"), facts));
}

test "rule order: systemd-* beats lifecycle and conditions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fx: Fixture = .{};
    var u = try unitFor(arena.allocator(), "systemd-foo");
    u.wanted_by = &.{"shutdown.target"};
    try expectClass(.unsupported, .systemd_unit, classify(u, fx.facts()));
    var v = try unitFor(arena.allocator(), "foo");
    v.wanted_by = &.{"shutdown.target"};
    v.exec_start = &.{};
    try expectClass(.unsupported, .lifecycle_target, classify(v, fx.facts()));
}

test "every rule has a distinct non-empty reason" {
    const rules = std.meta.tags(Rule);
    for (rules, 0..) |r, i| {
        try testing.expect(reason(r).len > 0);
        for (rules[0..i]) |p| try testing.expect(!std.mem.eql(u8, reason(r), reason(p)));
    }
}
