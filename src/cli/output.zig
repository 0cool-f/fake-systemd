// SPDX-License-Identifier: GPL-3.0-or-later
//! systemd-compatible output formats and exit codes for `systemctl` (spec §3.1). Wording, quoting,
//! table layout and exit codes were checked against systemd 257 (257.13-1~deb13u1) with
//! `systemctl --root=/`; `status`, `list-units` and its legend need a running systemd and are
//! unchecked.
const std = @import("std");
const Io = std.Io;

pub const Error = Io.Writer.Error;

/// Exit codes of systemctl(1) EXIT STATUS.
pub const Exit = struct {
    pub const success: u8 = 0;
    pub const failure: u8 = 1;
    /// `is-active`, `status` and `is-failed` queries for a unit that is not active.
    pub const not_active: u8 = 3;
    /// `status` and `is-enabled` for a unit that does not exist.
    pub const no_such_unit: u8 = 4;
    /// `start`/`stop`/`restart`/`reload` for a unit that does not exist.
    pub const not_installed: u8 = 5;
};

pub const Style = struct {
    /// Use `●`, `○`, `×`, `→`; otherwise ASCII `*`, `o`, `x`, `->`.
    utf8: bool = true,

    fn arrow(s: Style) []const u8 {
        return if (s.utf8) "→" else "->";
    }

    fn bullet(s: Style) []const u8 {
        return if (s.utf8) "●" else "*";
    }

    fn circle(s: Style) []const u8 {
        return if (s.utf8) "○" else "o";
    }

    fn cross(s: Style) []const u8 {
        return if (s.utf8) "×" else "x";
    }
};

pub const ActiveState = enum {
    active,
    reloading,
    inactive,
    failed,
    activating,
    deactivating,
    maintenance,

    pub fn text(s: ActiveState) []const u8 {
        return @tagName(s);
    }

    /// Exit code of `is-active` for this state.
    pub fn isActiveExit(s: ActiveState) u8 {
        return switch (s) {
            .active, .reloading => Exit.success,
            else => Exit.not_active,
        };
    }

    /// Exit code of `is-failed` for this state.
    pub fn isFailedExit(s: ActiveState) u8 {
        return if (s == .failed) Exit.success else Exit.failure;
    }
};

pub const EnabledState = enum {
    enabled,
    enabled_runtime,
    disabled,
    static,
    masked,
    masked_runtime,
    alias,
    indirect,
    linked,
    generated,
    not_found,

    pub fn text(s: EnabledState) []const u8 {
        return switch (s) {
            .enabled => "enabled",
            .enabled_runtime => "enabled-runtime",
            .disabled => "disabled",
            .static => "static",
            .masked => "masked",
            .masked_runtime => "masked-runtime",
            .alias => "alias",
            .indirect => "indirect",
            .linked => "linked",
            .generated => "generated",
            .not_found => "not-found",
        };
    }

    /// Exit code of `is-enabled` for this state.
    pub fn exitCode(s: EnabledState) u8 {
        return switch (s) {
            .enabled, .enabled_runtime, .static, .alias, .indirect, .generated => Exit.success,
            .not_found => Exit.no_such_unit,
            .disabled, .masked, .masked_runtime, .linked => Exit.failure,
        };
    }
};

/// Exit code of `is-enabled` over several units: 0 when any unit is in a success state, 4 when
/// every unit is `not-found`, otherwise 1.
pub fn isEnabledExit(states: []const EnabledState) u8 {
    var all_missing = true;
    for (states) |s| {
        if (s.exitCode() == Exit.success) return Exit.success;
        if (s != .not_found) all_missing = false;
    }
    return if (all_missing and states.len > 0) Exit.no_such_unit else Exit.failure;
}

/// Exit code of `list-unit-files`: 1 when nothing matched.
pub fn listUnitFilesExit(row_count: usize) u8 {
    return if (row_count == 0) Exit.failure else Exit.success;
}

/// Orders unit names as `list-unit-files` does: by type suffix, then by full name.
pub fn unitLessThan(_: void, a: []const u8, b: []const u8) bool {
    const by_type = std.mem.order(u8, std.fs.path.extension(a), std.fs.path.extension(b));
    if (by_type != .eq) return by_type == .lt;
    return std.mem.lessThan(u8, a, b);
}

/// `Failed to <verb> unit: Unit <name> does not exist`
pub fn writeUnitDoesNotExist(w: *Io.Writer, verb: []const u8, name: []const u8) Error!void {
    try w.print("Failed to {s} unit: Unit {s} does not exist\n", .{ verb, name });
}

/// `Failed to <verb> unit: Unit <path> is masked`
pub fn writeUnitMasked(w: *Io.Writer, verb: []const u8, path: []const u8) Error!void {
    try w.print("Failed to {s} unit: Unit {s} is masked\n", .{ verb, path });
}

/// Printed to stderr, with exit code 0, when `enable` or `disable` meets a unit without an
/// `[Install]` section.
pub const no_install_config =
    "The unit files have no installation config (WantedBy=, RequiredBy=, UpheldBy=,\n" ++
    "Also=, or Alias= settings in the [Install] section, and DefaultInstance= for\n" ++
    "template units). This means they are not meant to be enabled or disabled using systemctl.\n" ++
    " \n" ++
    "Possible reasons for having these kinds of units are:\n" ++
    "• A unit may be statically enabled by being symlinked from another unit's\n" ++
    "  .wants/, .requires/, or .upholds/ directory.\n" ++
    "• A unit's purpose may be to act as a helper for some other unit which has\n" ++
    "  a requirement dependency on it.\n" ++
    "• A unit may be started when needed via activation (socket, path, timer,\n" ++
    "  D-Bus, udev, scripted systemctl call, ...).\n" ++
    "• In case of template units, the unit is meant to be enabled with some\n" ++
    "  instance name specified.\n";

pub fn writeNoInstallConfig(w: *Io.Writer) Error!void {
    try w.writeAll(no_install_config);
}

pub const SystemState = enum {
    running,
    degraded,
    offline,
    starting,
    stopping,
    maintenance,

    pub fn text(s: SystemState) []const u8 {
        return @tagName(s);
    }

    pub fn exitCode(s: SystemState) u8 {
        return if (s == .running) Exit.success else Exit.failure;
    }
};

pub fn writeActive(w: *Io.Writer, state: ActiveState) Error!void {
    try w.print("{s}\n", .{state.text()});
}

pub fn writeEnabled(w: *Io.Writer, state: EnabledState) Error!void {
    try w.print("{s}\n", .{state.text()});
}

pub fn writeSystemState(w: *Io.Writer, state: SystemState) Error!void {
    try w.print("{s}\n", .{state.text()});
}

/// `Created symlink '<link>' → '<target>'.` systemd writes this line to stderr; `-q` suppresses it.
pub fn writeCreatedSymlink(w: *Io.Writer, style: Style, link: []const u8, target: []const u8) Error!void {
    try w.print("Created symlink '{s}' {s} '{s}'.\n", .{ link, style.arrow(), target });
}

/// `Created '<path>'.` for a marker file a backend writes in place of a symlink.
pub fn writeCreatedFile(w: *Io.Writer, path: []const u8) Error!void {
    try w.print("Created '{s}'.\n", .{path});
}

/// `Removed '<path>'.` systemd writes this line to stderr; `-q` suppresses it.
pub fn writeRemoved(w: *Io.Writer, path: []const u8) Error!void {
    try w.print("Removed '{s}'.\n", .{path});
}

/// `Unit <name> could not be found.` as printed by `status` for a missing unit.
pub fn writeUnitNotFound(w: *Io.Writer, name: []const u8) Error!void {
    try w.print("Unit {s} could not be found.\n", .{name});
}

pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const ShowOptions = struct {
    /// Requested property names; empty selects all.
    filter: []const []const u8 = &.{},
    value_only: bool = false,
    /// Prints a blank line first, separating consecutive units.
    separator: bool = false,
};

/// Writes `Key=Value` lines in the order of `properties`, restricted to `opts.filter`.
pub fn writeShow(w: *Io.Writer, properties: []const Property, opts: ShowOptions) Error!void {
    if (opts.separator) try w.writeAll("\n");
    for (properties) |p| {
        if (opts.filter.len > 0 and !contains(opts.filter, p.key)) continue;
        if (opts.value_only) {
            try w.print("{s}\n", .{p.value});
        } else {
            try w.print("{s}={s}\n", .{ p.key, p.value });
        }
    }
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |e| if (std.mem.eql(u8, e, item)) return true;
    return false;
}

fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn writePadded(w: *Io.Writer, text: []const u8, width: usize) Error!void {
    try w.writeAll(text);
    var n = displayWidth(text);
    while (n < width) : (n += 1) try w.writeByte(' ');
}

/// Writes rows with columns padded to their widest cell, one space apart; the last column is
/// not padded.
fn writeColumns(w: *Io.Writer, comptime n: usize, widths: [n]usize, cells: [n][]const u8) Error!void {
    inline for (0..n) |i| {
        if (i + 1 == n) {
            try w.writeAll(cells[i]);
        } else {
            try writePadded(w, cells[i], widths[i]);
            try w.writeByte(' ');
        }
    }
    try w.writeByte('\n');
}

pub const UnitFileRow = struct {
    unit: []const u8,
    state: []const u8,
    /// Null prints `-`.
    preset: ?[]const u8 = null,
};

pub const ListOptions = struct {
    no_legend: bool = false,
    plain: bool = false,
    all: bool = false,
    style: Style = .{},
};

/// `UNIT FILE  STATE  PRESET` table, then a blank line and `N unit files listed.`. `no_legend` drops
/// the header, the blank line and the count. Rows are expected in `unitLessThan` order.
pub fn writeUnitFiles(w: *Io.Writer, rows: []const UnitFileRow, opts: ListOptions) Error!void {
    var widths = [3]usize{ displayWidth("UNIT FILE"), displayWidth("STATE"), displayWidth("PRESET") };
    for (rows) |r| {
        widths[0] = @max(widths[0], displayWidth(r.unit));
        widths[1] = @max(widths[1], displayWidth(r.state));
        widths[2] = @max(widths[2], displayWidth(r.preset orelse "-"));
    }
    if (!opts.no_legend) try writeColumns(w, 3, widths, .{ "UNIT FILE", "STATE", "PRESET" });
    for (rows) |r| try writeColumns(w, 3, widths, .{ r.unit, r.state, r.preset orelse "-" });
    if (!opts.no_legend) try w.print("\n{d} unit files listed.\n", .{rows.len});
}

pub const UnitRow = struct {
    unit: []const u8,
    load: []const u8,
    active: []const u8,
    sub: []const u8,
    description: []const u8,
    /// Marked with a leading bullet unless `plain`.
    failed: bool = false,
};

/// `UNIT LOAD ACTIVE SUB DESCRIPTION` table with the systemd legend.
pub fn writeUnits(w: *Io.Writer, rows: []const UnitRow, opts: ListOptions) Error!void {
    var widths = [5]usize{ displayWidth("UNIT"), displayWidth("LOAD"), displayWidth("ACTIVE"), displayWidth("SUB"), 0 };
    for (rows) |r| {
        widths[0] = @max(widths[0], displayWidth(r.unit));
        widths[1] = @max(widths[1], displayWidth(r.load));
        widths[2] = @max(widths[2], displayWidth(r.active));
        widths[3] = @max(widths[3], displayWidth(r.sub));
    }
    if (!opts.no_legend) {
        if (!opts.plain) try w.writeAll("  ");
        try writeColumns(w, 5, widths, .{ "UNIT", "LOAD", "ACTIVE", "SUB", "DESCRIPTION" });
    }
    for (rows) |r| {
        if (!opts.plain) {
            try w.writeAll(if (r.failed) opts.style.bullet() else " ");
            try w.writeByte(' ');
        }
        try writeColumns(w, 5, widths, .{ r.unit, r.load, r.active, r.sub, r.description });
    }
    if (opts.no_legend) return;
    try w.writeAll(
        \\
        \\LOAD   = Reflects whether the unit definition was properly loaded.
        \\ACTIVE = The high-level unit activation state, i.e. generalization of SUB.
        \\SUB    = The low-level unit activation state, values depend on unit type.
        \\
    );
    try w.print("{d} loaded units listed.", .{rows.len});
    if (!opts.all) try w.writeAll(" Pass --all to see loaded but inactive units, too.");
    try w.writeAll("\nTo show all installed unit files use 'systemctl list-unit-files'.\n");
}

pub const StatusInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    /// `loaded`, `not-found`, `masked`, ...
    load_state: []const u8,
    fragment_path: ?[]const u8 = null,
    unit_file_state: ?[]const u8 = null,
    preset: ?[]const u8 = null,
    active_state: ActiveState,
    sub_state: []const u8,
    /// Text after `since `, for example `Sat 2025-01-01 10:00:00 UTC; 5min ago`.
    since: ?[]const u8 = null,
    main_pid: ?u32 = null,
    main_comm: ?[]const u8 = null,
    /// Timers: text after `Trigger: `, for example `Sat 2025-01-01 10:00:00 UTC; 5min left`.
    trigger: ?[]const u8 = null,
    /// Timers: the unit the timer starts.
    triggers: ?[]const u8 = null,
    /// Timers: the scheduler that fires the timer (`builtin` or `cron:<adapter>`).
    scheduler: ?[]const u8 = null,
    /// Timers: text after `Last run: `.
    last_run: ?[]const u8 = null,
};

/// First lines of `systemctl status`: title, `Loaded:`, `Active:` and optional `Main PID:`.
/// Log lines are appended by the caller after a blank line.
pub fn writeStatus(w: *Io.Writer, style: Style, info: StatusInfo) Error!void {
    try w.writeAll(switch (info.active_state) {
        .failed => style.cross(),
        .inactive => style.circle(),
        else => style.bullet(),
    });
    try w.print(" {s}", .{info.name});
    if (info.description) |d| try w.print(" - {s}", .{d});
    try w.writeByte('\n');

    try w.print("{s:>12} {s}", .{ "Loaded:", info.load_state });
    if (info.fragment_path != null or info.unit_file_state != null) {
        try w.writeAll(" (");
        var first = true;
        if (info.fragment_path) |p| {
            try w.writeAll(p);
            first = false;
        }
        if (info.unit_file_state) |s| {
            if (!first) try w.writeAll("; ");
            try w.writeAll(s);
            first = false;
        }
        if (info.preset) |p| {
            if (!first) try w.writeAll("; ");
            try w.print("preset: {s}", .{p});
        }
        try w.writeByte(')');
    }
    try w.writeByte('\n');

    try w.print("{s:>12} {s} ({s})", .{ "Active:", info.active_state.text(), info.sub_state });
    if (info.since) |s| try w.print(" since {s}", .{s});
    try w.writeByte('\n');

    if (info.main_pid) |pid| {
        try w.print("{s:>12} {d}", .{ "Main PID:", pid });
        if (info.main_comm) |c| try w.print(" ({s})", .{c});
        try w.writeByte('\n');
    }

    if (info.trigger) |t| try w.print("{s:>12} {s}\n", .{ "Trigger:", t });
    if (info.triggers) |t| try w.print("{s:>12} {s} {s}\n", .{ "Triggers:", style.bullet(), t });
    if (info.scheduler) |t| try w.print("{s:>12} {s}\n", .{ "Scheduler:", t });
    if (info.last_run) |t| try w.print("{s:>12} {s}\n", .{ "Last run:", t });
}

const testing = std.testing;

fn render(comptime f: anytype, args: anytype) ![]u8 {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

fn expectRender(expected: []const u8, comptime f: anytype, args: anytype) !void {
    const out = try render(f, args);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

test "exit codes follow systemctl(1)" {
    try testing.expectEqual(@as(u8, 0), Exit.success);
    try testing.expectEqual(@as(u8, 1), Exit.failure);
    try testing.expectEqual(@as(u8, 3), Exit.not_active);
    try testing.expectEqual(@as(u8, 4), Exit.no_such_unit);
    try testing.expectEqual(@as(u8, 5), Exit.not_installed);
}

test "is-active lines and exit codes" {
    try expectRender("active\n", writeActive, .{ActiveState.active});
    try expectRender("activating\n", writeActive, .{ActiveState.activating});
    try expectRender("failed\n", writeActive, .{ActiveState.failed});
    try testing.expectEqual(@as(u8, 0), ActiveState.active.isActiveExit());
    try testing.expectEqual(@as(u8, 0), ActiveState.reloading.isActiveExit());
    for ([_]ActiveState{ .inactive, .failed, .activating, .deactivating, .maintenance }) |s| {
        try testing.expectEqual(@as(u8, 3), s.isActiveExit());
    }
    try testing.expectEqual(@as(u8, 0), ActiveState.failed.isFailedExit());
    try testing.expectEqual(@as(u8, 1), ActiveState.active.isFailedExit());
}

test "is-enabled lines and exit codes" {
    try expectRender("enabled\n", writeEnabled, .{EnabledState.enabled});
    try expectRender("not-found\n", writeEnabled, .{EnabledState.not_found});
    try expectRender("masked-runtime\n", writeEnabled, .{EnabledState.masked_runtime});
    for ([_]EnabledState{ .enabled, .enabled_runtime, .static, .alias, .indirect, .generated }) |s| {
        try testing.expectEqual(@as(u8, 0), s.exitCode());
    }
    for ([_]EnabledState{ .disabled, .masked, .masked_runtime, .linked }) |s| {
        try testing.expectEqual(@as(u8, 1), s.exitCode());
    }
    try testing.expectEqual(@as(u8, 4), EnabledState.not_found.exitCode());
}

test "is-system-running" {
    try expectRender("offline\n", writeSystemState, .{SystemState.offline});
    try testing.expectEqual(@as(u8, 0), SystemState.running.exitCode());
    try testing.expectEqual(@as(u8, 1), SystemState.degraded.exitCode());
    try testing.expectEqual(@as(u8, 1), SystemState.offline.exitCode());
}

test "symlink and removal lines" {
    try expectRender(
        "Created symlink '/etc/x/foo.service' → '/usr/lib/foo.service'.\n",
        writeCreatedSymlink,
        .{ Style{}, "/etc/x/foo.service", "/usr/lib/foo.service" },
    );
    try expectRender(
        "Created symlink '/a' -> '/b'.\n",
        writeCreatedSymlink,
        .{ Style{ .utf8 = false }, "/a", "/b" },
    );
    try expectRender("Removed '/etc/x/foo.service'.\n", writeRemoved, .{"/etc/x/foo.service"});
    try expectRender("Unit foo.service could not be found.\n", writeUnitNotFound, .{"foo.service"});
}

const sample_props = [_]Property{
    .{ .key = "Id", .value = "foo.service" },
    .{ .key = "Names", .value = "foo.service" },
    .{ .key = "Description", .value = "" },
    .{ .key = "ActiveState", .value = "active" },
    .{ .key = "MainPID", .value = "42" },
};

test "show prints all properties without a filter" {
    try expectRender(
        "Id=foo.service\nNames=foo.service\nDescription=\nActiveState=active\nMainPID=42\n",
        writeShow,
        .{ @as([]const Property, &sample_props), ShowOptions{} },
    );
}

test "show filters properties and keeps empty values" {
    try expectRender(
        "Description=\nMainPID=42\n",
        writeShow,
        .{ @as([]const Property, &sample_props), ShowOptions{ .filter = &.{ "MainPID", "Description", "Missing" } } },
    );
}

test "show --value with several properties prints one value per line" {
    try expectRender(
        "active\n42\n",
        writeShow,
        .{ @as([]const Property, &sample_props), ShowOptions{ .filter = &.{ "ActiveState", "MainPID" }, .value_only = true } },
    );
}

test "show separates units with a blank line" {
    try expectRender(
        "\nId=foo.service\n",
        writeShow,
        .{ @as([]const Property, sample_props[0..1]), ShowOptions{ .separator = true } },
    );
}

test "list-unit-files layout and legend" {
    const rows = [_]UnitFileRow{
        .{ .unit = "sshd.service", .state = "enabled", .preset = "enabled" },
        .{ .unit = "a.timer", .state = "unsupported" },
    };
    try expectRender(
        "UNIT FILE    STATE       PRESET\n" ++
            "sshd.service enabled     enabled\n" ++
            "a.timer      unsupported -\n" ++
            "\n2 unit files listed.\n",
        writeUnitFiles,
        .{ @as([]const UnitFileRow, &rows), ListOptions{} },
    );
}

test "list-unit-files without legend or rows" {
    try expectRender("", writeUnitFiles, .{ @as([]const UnitFileRow, &.{}), ListOptions{ .no_legend = true } });
    try expectRender("UNIT FILE STATE PRESET\n\n0 unit files listed.\n", writeUnitFiles, .{ @as([]const UnitFileRow, &.{}), ListOptions{} });
}

test "list-units layout with bullet, plain and legend" {
    const rows = [_]UnitRow{
        .{ .unit = "a.service", .load = "loaded", .active = "active", .sub = "running", .description = "Alpha" },
        .{ .unit = "bb.service", .load = "loaded", .active = "failed", .sub = "failed", .description = "Beta", .failed = true },
    };
    const legend =
        "\nLOAD   = Reflects whether the unit definition was properly loaded.\n" ++
        "ACTIVE = The high-level unit activation state, i.e. generalization of SUB.\n" ++
        "SUB    = The low-level unit activation state, values depend on unit type.\n";
    try expectRender(
        "  UNIT       LOAD   ACTIVE SUB     DESCRIPTION\n" ++
            "  a.service  loaded active running Alpha\n" ++
            "● bb.service loaded failed failed  Beta\n" ++ legend ++
            "2 loaded units listed. Pass --all to see loaded but inactive units, too.\n" ++
            "To show all installed unit files use 'systemctl list-unit-files'.\n",
        writeUnits,
        .{ @as([]const UnitRow, &rows), ListOptions{} },
    );
    try expectRender(
        "a.service  loaded active running Alpha\n" ++
            "bb.service loaded failed failed  Beta\n",
        writeUnits,
        .{ @as([]const UnitRow, &rows), ListOptions{ .plain = true, .no_legend = true } },
    );
    try expectRender(
        "UNIT      LOAD   ACTIVE SUB     DESCRIPTION\n" ++
            "a.service loaded active running Alpha\n" ++ legend ++
            "1 loaded units listed.\n" ++
            "To show all installed unit files use 'systemctl list-unit-files'.\n",
        writeUnits,
        .{ @as([]const UnitRow, rows[0..1]), ListOptions{ .plain = true, .all = true } },
    );
}

test "columns are padded by display width, not bytes" {
    const rows = [_]UnitFileRow{.{ .unit = "é.service", .state = "enabled" }};
    try expectRender(
        "UNIT FILE STATE   PRESET\né.service enabled -\n\n1 unit files listed.\n",
        writeUnitFiles,
        .{ @as([]const UnitFileRow, &rows), ListOptions{} },
    );
}

test "status block for an active unit" {
    try expectRender(
        "● foo.service - Foo daemon\n" ++
            "     Loaded: loaded (/etc/systemd/system/foo.service; enabled; preset: disabled)\n" ++
            "     Active: active (running) since Sat 2025-01-01 10:00:00 UTC; 5min ago\n" ++
            "   Main PID: 123 (foo)\n",
        writeStatus,
        .{ Style{}, StatusInfo{
            .name = "foo.service",
            .description = "Foo daemon",
            .load_state = "loaded",
            .fragment_path = "/etc/systemd/system/foo.service",
            .unit_file_state = "enabled",
            .preset = "disabled",
            .active_state = .active,
            .sub_state = "running",
            .since = "Sat 2025-01-01 10:00:00 UTC; 5min ago",
            .main_pid = 123,
            .main_comm = "foo",
        } },
    );
}

test "status block for inactive, failed and missing units" {
    try expectRender(
        "○ foo.service\n     Loaded: loaded (/f; disabled)\n     Active: inactive (dead)\n",
        writeStatus,
        .{ Style{}, StatusInfo{
            .name = "foo.service",
            .load_state = "loaded",
            .fragment_path = "/f",
            .unit_file_state = "disabled",
            .active_state = .inactive,
            .sub_state = "dead",
        } },
    );
    try expectRender(
        "x foo.service - F\n     Loaded: loaded\n     Active: failed (failed)\n   Main PID: 7\n",
        writeStatus,
        .{ Style{ .utf8 = false }, StatusInfo{
            .name = "foo.service",
            .description = "F",
            .load_state = "loaded",
            .active_state = .failed,
            .sub_state = "failed",
            .main_pid = 7,
        } },
    );
}

test "observed systemd 257 transcripts" {
    try expectRender(
        "Created symlink '/etc/systemd/system/multi-user.target.wants/foo.service' → '/usr/lib/systemd/system/foo.service'.\n",
        writeCreatedSymlink,
        .{ Style{}, "/etc/systemd/system/multi-user.target.wants/foo.service", "/usr/lib/systemd/system/foo.service" },
    );
    try expectRender("Created symlink '/etc/systemd/system/foo.service' → '/dev/null'.\n", writeCreatedSymlink, .{ Style{}, "/etc/systemd/system/foo.service", "/dev/null" });
    try expectRender("Removed '/etc/systemd/system/multi-user.target.wants/foo.service'.\n", writeRemoved, .{"/etc/systemd/system/multi-user.target.wants/foo.service"});
    try expectRender("Failed to enable unit: Unit missing.service does not exist\n", writeUnitDoesNotExist, .{ "enable", "missing.service" });
    try expectRender("Failed to preset unit: Unit /run/systemd/system/foo.service is masked\n", writeUnitMasked, .{ "preset", "/run/systemd/system/foo.service" });
    try expectRender(
        "UNIT FILE   STATE    PRESET\nfoo.service disabled enabled\n\n1 unit files listed.\n",
        writeUnitFiles,
        .{ @as([]const UnitFileRow, &.{.{ .unit = "foo.service", .state = "disabled", .preset = "enabled" }}), ListOptions{} },
    );
    try expectRender(
        "als.service  enabled enabled\nals2.service alias   -\n",
        writeUnitFiles,
        .{ @as([]const UnitFileRow, &.{
            .{ .unit = "als.service", .state = "enabled", .preset = "enabled" },
            .{ .unit = "als2.service", .state = "alias" },
        }), ListOptions{ .no_legend = true } },
    );
}

test "install-config notice matches systemd 257 byte for byte" {
    try expectRender(no_install_config, writeNoInstallConfig, .{});
    try testing.expect(std.mem.startsWith(u8, no_install_config, "The unit files have no installation config (WantedBy=, RequiredBy=, UpheldBy=,\n"));
    try testing.expect(std.mem.indexOf(u8, no_install_config, "\n \nPossible reasons") != null);
    try testing.expect(std.mem.endsWith(u8, no_install_config, "  instance name specified.\n"));
}

test "is-enabled exit code over several units" {
    const E = EnabledState;
    try testing.expectEqual(@as(u8, 0), isEnabledExit(&.{ E.not_found, E.static }));
    try testing.expectEqual(@as(u8, 0), isEnabledExit(&.{ E.enabled, E.not_found }));
    try testing.expectEqual(@as(u8, 4), isEnabledExit(&.{ E.not_found, E.not_found }));
    try testing.expectEqual(@as(u8, 4), isEnabledExit(&.{E.not_found}));
    try testing.expectEqual(@as(u8, 1), isEnabledExit(&.{ E.not_found, E.disabled }));
    try testing.expectEqual(@as(u8, 1), isEnabledExit(&.{ E.masked_runtime, E.not_found }));
    try testing.expectEqual(@as(u8, 1), isEnabledExit(&.{ E.masked_runtime, E.disabled }));
    try testing.expectEqual(@as(u8, 1), isEnabledExit(&.{}));
}

test "observed single-unit is-enabled states" {
    try testing.expectEqual(@as(u8, 1), EnabledState.disabled.exitCode());
    try testing.expectEqual(@as(u8, 1), EnabledState.masked.exitCode());
    try testing.expectEqual(@as(u8, 1), EnabledState.masked_runtime.exitCode());
    try testing.expectEqual(@as(u8, 1), EnabledState.linked.exitCode());
    try testing.expectEqual(@as(u8, 0), EnabledState.enabled_runtime.exitCode());
    try testing.expectEqual(@as(u8, 0), EnabledState.indirect.exitCode());
    try testing.expectEqual(@as(u8, 0), EnabledState.alias.exitCode());
    try testing.expectEqual(@as(u8, 0), EnabledState.static.exitCode());
    try testing.expectEqual(@as(u8, 4), EnabledState.not_found.exitCode());
}

test "list-unit-files exit code and ordering" {
    try testing.expectEqual(@as(u8, 1), listUnitFilesExit(0));
    try testing.expectEqual(@as(u8, 0), listUnitFilesExit(3));
    var names = [_][]const u8{
        "getty@.service", "foo.timer",    "dbus.service", "dbus-org.freedesktop.login1.service",
        "tmp.mount",      "als2.service", "als.service",  "getty-static.service",
        "basic.target",   "dbus.socket",  "x.automount",
    };
    std.mem.sort([]const u8, &names, {}, unitLessThan);
    const expected = [_][]const u8{
        "x.automount",  "tmp.mount",            "als.service",    "als2.service", "dbus-org.freedesktop.login1.service",
        "dbus.service", "getty-static.service", "getty@.service", "dbus.socket",  "basic.target",
        "foo.timer",
    };
    for (expected, names) |e, n| try testing.expectEqualStrings(e, n);
}

/// Exit code of `is-active` over several units: 0 when at least one unit is active.
pub fn isActiveExitAll(states: []const ActiveState) u8 {
    for (states) |s| {
        if (s.isActiveExit() == Exit.success) return Exit.success;
    }
    return Exit.not_active;
}

test "is-active exit code over several units" {
    const A = ActiveState;
    try testing.expectEqual(@as(u8, 0), isActiveExitAll(&.{ A.inactive, A.active }));
    try testing.expectEqual(@as(u8, 0), isActiveExitAll(&.{ A.active, A.failed }));
    try testing.expectEqual(@as(u8, 3), isActiveExitAll(&.{ A.inactive, A.failed }));
    try testing.expectEqual(@as(u8, 3), isActiveExitAll(&.{}));
}
