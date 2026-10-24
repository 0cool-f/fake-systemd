//! Runtime verbs: start, stop, restart, reload and friends, kill and power (§3.1).
const std = @import("std");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const backend_pkg = @import("../backend/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const lifecycle = @import("lifecycle.zig");
const units = @import("units.zig");

const Name = unit.name.Name;
const Verb = cli.systemctl.Verb;
const Exit = cli.output.Exit;

/// Verbs that leave an excluded unit alone instead of failing.
fn toleratesUnsupported(verb: Verb) bool {
    return switch (verb) {
        .stop, .try_restart, .try_reload_or_restart => true,
        else => false,
    };
}

fn isActive(s: *Session, service: []const u8) bool {
    const st = s.deps.backend.status(s.env(), service) catch return false;
    return st.state == .active or st.state == .activating or st.state == .reloading;
}

fn call(s: *Session, verb: Verb, plan: *const pipeline.Plan, service: []const u8) u8 {
    const b = s.deps.backend;
    const env = s.env();
    const result = switch (verb) {
        .start => b.start(env, service),
        .stop => b.stop(env, service),
        .restart, .try_restart => b.restart(env, service),
        .reload => b.reload(env, service),
        .reload_or_restart, .try_reload_or_restart => if (plan.unit.?.exec_reload.len > 0)
            b.reload(env, service)
        else
            b.restart(env, service),
        else => unreachable,
    };
    result catch |e| return s.backendFailed(verb.name(), plan.name.full, e);
    return Exit.success;
}

fn one(s: *Session, verb: Verb, name: Name) !u8 {
    const plan = try pipeline.prepare(s, name);
    if (plan.outcome == .not_found) {
        try cli.output.writeUnitDoesNotExist(s.err(), verb.name(), name.full);
        return Exit.not_installed;
    }
    if (plan.outcome == .unsupported and toleratesUnsupported(verb)) {
        s.ctx.diag.notice("{s}: not translated ({s}), nothing to do", .{ name.full, plan.class.?.reason });
        return Exit.success;
    }
    if (try lifecycle.earlyOutcome(s, verb.name(), &plan)) |code| return code;

    const service = plan.service().?;
    switch (verb) {
        .stop, .reload => {},
        .try_restart, .try_reload_or_restart => if (!isActive(s, service)) return Exit.success,
        else => {},
    }
    switch (verb) {
        .stop, .reload => {},
        else => _ = try pipeline.commit(s, &plan, .explicit),
    }
    return call(s, verb, &plan, service);
}

pub fn run(s: *Session, verb: Verb) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var agg: units.Aggregate = .{};
    for (names) |n| {
        if (s.ctx.offline) {
            s.offlineNotice(verb.name(), n.full);
            continue;
        }
        agg.note(try one(s, verb, n));
    }
    return agg.code;
}

fn killSignal(s: *Session) []const u8 {
    for (s.req.ignored) |o| {
        if (std.mem.eql(u8, o.name, "signal")) return o.value orelse "TERM";
    }
    return "TERM";
}

pub fn kill(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var agg: units.Aggregate = .{};
    for (names) |n| {
        if (s.ctx.offline) {
            s.offlineNotice("kill", n.full);
            continue;
        }
        const plan = try pipeline.prepare(s, n);
        if (plan.outcome == .not_found) {
            try cli.output.writeUnitDoesNotExist(s.err(), "kill", n.full);
            agg.note(Exit.not_installed);
        } else if (try lifecycle.earlyOutcome(s, "kill", &plan)) |code| {
            agg.note(code);
        } else if (s.deps.backend.kill(s.env(), plan.service().?, killSignal(s))) {} else |e| {
            agg.note(s.backendFailed("kill", n.full, e));
        }
    }
    return agg.code;
}

pub fn power(s: *Session, verb: Verb) !u8 {
    if (s.ctx.offline) {
        s.ctx.diag.notice("init is not running, not contacting it: skipping '{s}'", .{verb.name()});
        return Exit.success;
    }
    const action: backend_pkg.interface.Power = switch (verb) {
        .reboot => .reboot,
        .poweroff => .poweroff,
        .halt => .halt,
        else => unreachable,
    };
    s.deps.backend.power(s.env(), action) catch |e| return s.backendFailed(verb.name(), "system", e);
    return Exit.success;
}

const tool_dirs = [_][]const u8{ "/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin" };

fn hasTool(s: *Session, tool: []const u8) bool {
    for (tool_dirs) |dir| {
        const path = std.fs.path.join(s.ctx.gpa, &.{ dir, tool }) catch return false;
        const st = s.ctx.fs.stat(path) catch continue;
        if (st.kind == .file) return true;
    }
    return false;
}

/// suspend and hibernate are delegated to `loginctl`.
pub fn sleepVerb(s: *Session, verb: Verb) !u8 {
    if (s.ctx.offline) {
        s.ctx.diag.notice("init is not running, not contacting it: skipping '{s}'", .{verb.name()});
        return Exit.success;
    }
    if (!hasTool(s, "loginctl")) {
        s.ctx.diag.err("loginctl is not installed, cannot {s}", .{verb.name()});
        return Exit.failure;
    }
    const res = s.runner().run(s.ctx.gpa, &.{ "loginctl", verb.name() }, .inherit) catch |e| {
        s.ctx.diag.err("cannot run loginctl: {t}", .{e});
        return Exit.failure;
    };
    return res.code;
}
