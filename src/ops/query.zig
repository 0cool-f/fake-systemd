// SPDX-License-Identifier: GPL-3.0-or-later
//! Query verbs: is-active, is-enabled, is-failed, status, show, cat, list-units,
//! list-unit-files, list-timers and is-system-running (§3.1).
const std = @import("std");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const backend_pkg = @import("../backend/root.zig");
const Session = @import("session.zig");
const pipeline = @import("pipeline.zig");
const preset = @import("preset.zig");
const units = @import("units.zig");
const timers = @import("timers.zig");

const Name = unit.name.Name;
const output = cli.output;
const Exit = output.Exit;

/// Prepares a unit for a query; a unit that cannot be loaded is reported and treated as absent.
fn prepareQuiet(s: *Session, name: Name) !?pipeline.Plan {
    return pipeline.prepare(s, name) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            s.ctx.diag.err("{s}: cannot load unit: {t}", .{ name.full, e });
            return null;
        },
    };
}

fn activeStatus(s: *Session, plan: pipeline.Plan) backend_pkg.interface.Status {
    if (plan.outcome == .timer) return .{ .state = timers.activeState(s, plan.name) };
    if (s.ctx.offline) return .{ .state = .inactive };
    const service = plan.service() orelse return .{ .state = .inactive };
    return s.deps.backend.status(s.env(), service) catch .{ .state = .inactive };
}

fn enabledState(s: *Session, plan: pipeline.Plan) output.EnabledState {
    const installable = if (plan.unit) |u| pipeline.hasInstallConfig(u) else false;
    switch (plan.outcome) {
        .not_found => return .not_found,
        .masked => return .masked,
        .unsupported => return .disabled,
        .timer => {
            const st = timers.state(s, plan.name) catch return .disabled;
            if (st.armed) return .enabled;
            return if (installable) .disabled else .static;
        },
        .template, .no_backend => return if (installable) .disabled else .static,
        .conflict => return .disabled,
        .native => |n| return s.deps.backend.isEnabled(s.env(), n.name) catch .disabled,
        .generate => |g| {
            if (!installable) return .static;
            if (plan.class) |c| if (c.kind == .timer_service) return .static;
            return s.deps.backend.isEnabled(s.env(), g.generated.service_name) catch .disabled;
        },
    }
}

pub fn isActive(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var any_active = false;
    for (names) |n| {
        var state: output.ActiveState = .inactive;
        if (!s.ctx.offline) {
            if (try prepareQuiet(s, n)) |plan| state = activeStatus(s, plan).state;
        }
        if (!s.quiet()) try output.writeActive(s.out(), state);
        if (state.isActiveExit() == Exit.success) any_active = true;
    }
    return if (any_active) Exit.success else Exit.not_active;
}

pub fn isFailed(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var any_failed = false;
    for (names) |n| {
        var state: output.ActiveState = .inactive;
        if (!s.ctx.offline) {
            if (try prepareQuiet(s, n)) |plan| state = activeStatus(s, plan).state;
        }
        if (!s.quiet()) try output.writeActive(s.out(), state);
        if (state.isFailedExit() == Exit.success) any_failed = true;
    }
    return if (any_failed) Exit.success else Exit.failure;
}

pub fn isEnabled(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    const states = try s.ctx.gpa.alloc(output.EnabledState, names.len);
    for (names, states) |n, *st| {
        st.* = if (try prepareQuiet(s, n)) |plan| enabledState(s, plan) else .not_found;
        if (!s.quiet()) try output.writeEnabled(s.out(), st.*);
    }
    return output.isEnabledExit(states);
}

pub fn isSystemRunning(s: *Session) !u8 {
    const state: output.SystemState = if (s.ctx.offline) .offline else .running;
    if (!s.quiet()) try output.writeSystemState(s.out(), state);
    return state.exitCode();
}

fn subState(state: output.ActiveState) []const u8 {
    return switch (state) {
        .active => "running",
        .inactive => "dead",
        .failed => "failed",
        .activating => "start",
        .deactivating => "stop",
        .reloading => "reload",
        .maintenance => "maintenance",
    };
}

fn loadState(plan: pipeline.Plan) []const u8 {
    return switch (plan.outcome) {
        .not_found => "not-found",
        .masked => "masked",
        else => "loaded",
    };
}

fn writePendingBackups(s: *Session, name: Name) !void {
    const idx = try s.index(.read);
    const entry = idx.findUnit(name.full) orelse return;
    for (entry.files) |f| {
        for ([_]index_pkg.Layout.BackupKind{ .fsnew, .fssave }) |kind| {
            const path = try s.layout.backupPath(s.ctx.gpa, f.path, kind);
            if (!s.ctx.fs.exists(path)) continue;
            try s.out().print("{s:>12} pending {s} backup {s}\n", .{ "Backups:", @tagName(kind), path });
        }
    }
}

const index_pkg = @import("../index/root.zig");

fn statusOne(s: *Session, name: Name) !u8 {
    const plan = (try prepareQuiet(s, name)) orelse return Exit.no_such_unit;
    if (plan.outcome == .not_found) {
        try output.writeUnitNotFound(s.err(), name.full);
        return Exit.no_such_unit;
    }
    const st = activeStatus(s, plan);
    const file_state: ?[]const u8 = switch (plan.outcome) {
        .masked => null,
        else => enabledState(s, plan).text(),
    };
    var timer_info: ?timers.State = null;
    var texts: ?timers.StatusTexts = null;
    var service: ?[]const u8 = null;
    if (plan.outcome == .timer) {
        timer_info = try timers.state(s, name);
        texts = try timers.statusTexts(s, timer_info.?);
        service = timers.serviceOfEntry(s, name);
    }
    try output.writeStatus(s.out(), s.style(), .{
        .name = name.full,
        .description = if (plan.unit) |u| u.description else null,
        .load_state = loadState(plan),
        .fragment_path = plan.fragmentPath(),
        .unit_file_state = file_state,
        .active_state = st.state,
        .sub_state = if (plan.outcome == .timer and st.state == .active) "waiting" else subState(st.state),
        .main_pid = st.pid,
        .trigger = if (texts) |t| t.trigger else null,
        .triggers = service,
        .scheduler = if (timer_info) |t| (if (t.armed) t.scheduler else null) else null,
        .last_run = if (texts) |t| t.last_run else null,
    });
    switch (plan.outcome) {
        .unsupported => try s.out().print("{s:>12} not translated by fake-systemd: {s}\n", .{ "Note:", plan.class.?.reason }),
        .native => |n| try s.out().print("{s:>12} served by native service '{s}' ({s})\n", .{ "Note:", n.name, n.path }),
        else => {},
    }
    try writePendingBackups(s, name);
    return st.state.isActiveExit();
}

pub fn status(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) {
        s.ctx.diag.notice("status without a unit is not supported", .{});
        return Exit.success;
    }
    var agg: units.Aggregate = .{};
    for (names, 0..) |n, i| {
        if (i > 0) try s.out().writeByte('\n');
        const code = try statusOne(s, n);
        if (code != 0 and (agg.code == 0 or code == Exit.no_such_unit)) agg.code = code;
    }
    return agg.code;
}

fn showOne(s: *Session, name: Name, separator: bool) !void {
    const plan = try prepareQuiet(s, name);
    const found = plan != null and plan.?.outcome != .not_found;
    var st: backend_pkg.interface.Status = .{ .state = .inactive };
    var file_state: []const u8 = "";
    var fragment: []const u8 = "";
    var description: []const u8 = name.full;
    var type_name: []const u8 = "";
    if (found) {
        const p = plan.?;
        st = activeStatus(s, p);
        file_state = enabledState(s, p).text();
        fragment = p.fragmentPath() orelse "";
        if (p.unit) |u| {
            if (u.description) |d| description = d;
            type_name = @tagName(u.service_type);
        }
    }
    const pid = try std.fmt.allocPrint(s.ctx.gpa, "{d}", .{st.pid orelse 0});
    const props = [_]output.Property{
        .{ .key = "Id", .value = name.full },
        .{ .key = "Names", .value = name.full },
        .{ .key = "Description", .value = description },
        .{ .key = "LoadState", .value = if (plan) |p| loadState(p) else "error" },
        .{ .key = "ActiveState", .value = st.state.text() },
        .{ .key = "SubState", .value = subState(st.state) },
        .{ .key = "UnitFileState", .value = file_state },
        .{ .key = "FragmentPath", .value = fragment },
        .{ .key = "MainPID", .value = pid },
        .{ .key = "ExecMainStatus", .value = "0" },
        .{ .key = "Type", .value = type_name },
    };
    try output.writeShow(s.out(), &props, .{
        .filter = s.req.options.properties,
        .value_only = s.req.options.value,
        .separator = separator,
    });
}

pub fn show(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    for (names, 0..) |n, i| try showOne(s, n, i > 0);
    return Exit.success;
}

fn catOne(s: *Session, name: Name, first: bool) !u8 {
    const resolved = try unit.resolve.resolve(s.ctx.gpa, s.ctx.fs.*, s.resolveOptions(), name);
    if (resolved.state == .not_found) {
        s.ctx.diag.err("No files found for {s}.", .{name.full});
        return Exit.failure;
    }
    if (!first) try s.out().writeByte('\n');
    if (resolved.state == .masked) {
        try s.out().print("# {s}\n# (masked)\n", .{resolved.fragment.?.path});
        return Exit.success;
    }
    for (resolved.files, 0..) |ref, i| {
        if (i > 0) try s.out().writeByte('\n');
        const content = try s.ctx.fs.readFileAlloc(s.ctx.gpa, ref.read_path, unit.resolve.max_unit_file_size);
        try s.out().print("# {s}\n{s}", .{ ref.path, content });
        if (content.len > 0 and content[content.len - 1] != '\n') try s.out().writeByte('\n');
    }
    return Exit.success;
}

pub fn cat(s: *Session) !u8 {
    const names = (try units.parseArgs(s)) orelse return Exit.failure;
    if (names.len == 0) return units.tooFew(s);
    var agg: units.Aggregate = .{};
    for (names, 0..) |n, i| agg.note(try catOne(s, n, i == 0));
    return agg.code;
}

fn listedState(s: *Session, listed: unit.resolve.Listed, name: Name) ![]const u8 {
    if (listed.masked) return "masked";
    if (listed.alias_of != null) return "alias";
    const plan = (try prepareQuiet(s, name)) orelse return "bad";
    return switch (plan.outcome) {
        .unsupported => "unsupported",
        else => enabledState(s, plan).text(),
    };
}

fn matchesFilter(filter: []const []const u8, value: []const u8) bool {
    if (filter.len == 0) return true;
    for (filter) |f| if (std.mem.eql(u8, f, value)) return true;
    return false;
}

pub fn listUnitFiles(s: *Session) !u8 {
    const gpa = s.ctx.gpa;
    const listed = try unit.resolve.list(gpa, s.ctx.fs.*, s.resolveOptions());
    const rules = try preset.loadRules(s);
    var rows: std.ArrayList(output.UnitFileRow) = .empty;
    for (listed) |l| {
        const name = try unit.name.parse(gpa, l.name);
        if (!matchesFilter(s.req.options.types, name.kind.suffix())) continue;
        const state = try listedState(s, l, name);
        if (!matchesFilter(s.req.options.states, state)) continue;
        const preset_text: ?[]const u8 = if (preset.lookup(rules, name.full)) |a| (if (a == .enable) "enabled" else "disabled") else null;
        try rows.append(gpa, .{ .unit = l.name, .state = state, .preset = preset_text });
    }
    std.mem.sort(output.UnitFileRow, rows.items, {}, struct {
        fn lessThan(_: void, a: output.UnitFileRow, b: output.UnitFileRow) bool {
            return output.unitLessThan({}, a.unit, b.unit);
        }
    }.lessThan);
    const o = s.req.options;
    try output.writeUnitFiles(s.out(), rows.items, .{ .no_legend = o.no_legend, .plain = o.plain, .all = o.all, .style = s.style() });
    return output.listUnitFilesExit(rows.items.len);
}

pub fn listUnits(s: *Session) !u8 {
    const gpa = s.ctx.gpa;
    const o = s.req.options;
    const idx = try s.index(.read);
    var rows: std.ArrayList(output.UnitRow) = .empty;
    for (idx.units.items) |entry| {
        const name = unit.name.parse(gpa, entry.name) catch continue;
        if (!matchesFilter(o.types, name.kind.suffix())) continue;
        const plan = (try prepareQuiet(s, name)) orelse continue;
        if (plan.service() == null) continue;
        const st = activeStatus(s, plan);
        if (!o.all and st.state != .active) continue;
        if (!matchesFilter(o.states, st.state.text())) continue;
        try rows.append(gpa, .{
            .unit = entry.name,
            .load = "loaded",
            .active = st.state.text(),
            .sub = subState(st.state),
            .description = if (plan.unit) |u| u.description orelse entry.name else entry.name,
            .failed = st.state == .failed,
        });
    }
    std.mem.sort(output.UnitRow, rows.items, {}, struct {
        fn lessThan(_: void, a: output.UnitRow, b: output.UnitRow) bool {
            return std.mem.lessThan(u8, a.unit, b.unit);
        }
    }.lessThan);
    try output.writeUnits(s.out(), rows.items, .{ .no_legend = o.no_legend, .plain = o.plain, .all = o.all, .style = s.style() });
    return Exit.success;
}

pub fn listTimers(s: *Session) !u8 {
    return timers.list(s);
}
