// SPDX-License-Identifier: GPL-3.0-or-later
//! `systemctl` and `journalctl` entry points: dispatch of parsed requests onto the verb modules.
const std = @import("std");
const Io = std.Io;
const core = @import("../core/root.zig");
const cli = @import("../cli/root.zig");
const backend_pkg = @import("../backend/root.zig");

pub const Session = @import("session.zig");
pub const Deps = Session.Deps;
pub const pipeline = @import("pipeline.zig");
pub const native = @import("native.zig");
pub const units = @import("units.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const runtime = @import("runtime.zig");
pub const query = @import("query.zig");
pub const reload = @import("reload.zig");
pub const edit = @import("edit.zig");
pub const preset = @import("preset.zig");
pub const pending = @import("pending.zig");
pub const journal = @import("journal.zig");
pub const journal_time = @import("journal_time.zig");
pub const timers = @import("timers.zig");

const Verb = cli.systemctl.Verb;
const Exit = cli.output.Exit;

/// Applies the global options of a request to the context.
pub fn applyOptions(ctx: *core.Context, o: cli.systemctl.Options) void {
    ctx.scope = o.scope;
    ctx.dry_run = o.dry_run or ctx.config.dry_run;
    ctx.offline = ctx.offline or o.root != null;
    quietDiag(ctx, o.quiet);
}

fn quietDiag(ctx: *core.Context, quiet: bool) void {
    if (!quiet) return;
    if (@backingInt(ctx.diag.threshold) > @backingInt(core.Diag.Level.warning)) ctx.diag.threshold = .warning;
}

fn isQuery(verb: Verb) bool {
    return switch (verb) {
        .is_active, .is_enabled, .is_failed, .status, .show, .cat, .list_units, .list_unit_files, .list_timers, .is_system_running => true,
        else => false,
    };
}

fn ignoredNotice(ctx: *core.Context, req: cli.systemctl.Request) void {
    for (req.unknown_options) |opt| ctx.diag.warn("unknown option '{s}' ignored", .{opt});
    if (req.ignored.len == 0) return;
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    for (req.ignored, 0..) |o, i| {
        w.print("{s}--{s}", .{ if (i > 0) " " else "", o.name }) catch break;
    }
    ctx.diag.info("accepted but ignored options: {s}", .{w.buffered()});
}

/// Verbs that write units or the index, directly or by translating a unit on the way.
fn needsTrustedConfig(verb: Verb) bool {
    return verb.mutates() or switch (verb) {
        .start, .restart, .try_restart, .reload_or_restart, .try_reload_or_restart => true,
        else => false,
    };
}

fn dispatch(s: *Session, verb: Verb) !u8 {
    return switch (verb) {
        .daemon_reload, .daemon_reexec => reload.run(s),
        .start, .stop, .restart, .try_restart, .reload, .reload_or_restart, .try_reload_or_restart => runtime.run(s, verb),
        .enable => lifecycle.enable(s),
        .disable => lifecycle.disable(s),
        .reenable => lifecycle.reenable(s),
        .mask => lifecycle.mask(s),
        .unmask => lifecycle.unmask(s),
        .revert => lifecycle.revert(s),
        .is_active => query.isActive(s),
        .is_enabled => query.isEnabled(s),
        .is_failed => query.isFailed(s),
        .status => query.status(s),
        .show => query.show(s),
        .cat => query.cat(s),
        .edit => edit.run(s),
        .list_units => query.listUnits(s),
        .list_unit_files => query.listUnitFiles(s),
        .list_timers => query.listTimers(s),
        .is_system_running => query.isSystemRunning(s),
        .preset => preset.preset(s),
        .preset_all => preset.presetAll(s),
        .kill => runtime.kill(s),
        .reboot, .poweroff, .halt => runtime.power(s, verb),
        .suspend_, .hibernate => runtime.sleepVerb(s, verb),
        .set_property, .set_environment, .unset_environment, .import_environment => {
            s.ctx.diag.notice("'{s}' has no effect without systemd and is ignored", .{verb.name()});
            return Exit.success;
        },
    };
}

fn versionText(w: *Io.Writer, backend_name: []const u8) !void {
    try w.print("fake-systemd {s}\nbackend: {s}\n", .{ backend_pkg.interface.version, backend_name });
}

/// Runs a parsed `systemctl` request and returns the exit code.
pub fn systemctl(ctx: *core.Context, deps: Deps, req: cli.systemctl.Request) u8 {
    applyOptions(ctx, req.options);
    const code = systemctlInner(ctx, deps, req);
    deps.out.flush() catch |e| ctx.diag.err("cannot write standard output: {t}", .{e});
    deps.err.flush() catch |e| ctx.diag.err("cannot write standard error: {t}", .{e});
    return code;
}

fn systemctlInner(ctx: *core.Context, deps: Deps, req: cli.systemctl.Request) u8 {
    switch (req.mode) {
        .help => {
            deps.out.writeAll(cli.systemctl.help_text) catch return Exit.failure;
            return Exit.success;
        },
        .version => {
            versionText(deps.out, deps.backend.name()) catch return Exit.failure;
            return Exit.success;
        },
        .run => {},
    }
    ignoredNotice(ctx, req);
    if (req.command) |command| switch (command) {
        .known => |verb| if (ctx.config.load_error) |problem| if (needsTrustedConfig(verb)) {
            ctx.diag.err("refusing to run '{s}': the configuration is not usable: {s}", .{ verb.name(), problem });
            return Exit.failure;
        },
        .unknown => {},
    };
    var s = Session.init(ctx, deps, req) catch |e| {
        ctx.diag.err("cannot start: {t}", .{e});
        return Exit.failure;
    };
    const command = req.command orelse cli.systemctl.Command{ .known = .list_units };
    var code: u8 = Exit.success;
    switch (command) {
        .unknown => |word| ctx.diag.warn("unknown verb '{s}' ignored", .{word}),
        .known => |verb| {
            s.runtime_verb = !isQuery(verb);
            code = dispatch(&s, verb) catch |e| blk: {
                if (e == error.UnitFileTooLarge and units.reportOversized(&s)) break :blk Exit.failure;
                ctx.diag.err("{s}: {t}", .{ verb.name(), e });
                break :blk Exit.failure;
            };
        },
    }
    if (!s.finish() and code == Exit.success) code = Exit.failure;
    return code;
}

/// Parses `args` (without the program name) and runs them; parse failures print and exit 1.
pub fn systemctlArgs(ctx: *core.Context, deps: Deps, args: []const []const u8) u8 {
    const result = cli.systemctl.parse(ctx.gpa, args) catch |e| {
        ctx.diag.err("cannot parse arguments: {t}", .{e});
        return Exit.failure;
    };
    switch (result) {
        .ok => |req| return systemctl(ctx, deps, req),
        .err => |failure| {
            ctx.diag.err("{f}", .{FailureFmt{ .failure = failure }});
            return Exit.failure;
        },
    }
}

const FailureFmt = struct {
    failure: cli.systemctl.Failure,

    pub fn format(f: FailureFmt, w: *Io.Writer) Io.Writer.Error!void {
        try f.failure.format(w);
    }
};

const journalctl_help =
    \\journalctl [OPTIONS...] [MATCHES...]
    \\
    \\Query the logs of services translated by fake-systemd.
    \\
;

/// Runs a parsed `journalctl` request.
pub fn journalctl(ctx: *core.Context, deps: Deps, req: cli.journalctl.Request) u8 {
    quietDiag(ctx, req.options.quiet);
    switch (req.mode) {
        .help => deps.out.writeAll(journalctl_help) catch return Exit.failure,
        .version => versionText(deps.out, deps.backend.name()) catch return Exit.failure,
        .run => {
            const tty = Io.File.stdout().isTty(ctx.io) catch false;
            const code = journal.show(ctx, .{ .out = deps.out, .runner = deps.runner, .detected = deps.detected, .tty = tty }, req);
            deps.out.flush() catch |e| ctx.diag.err("cannot write standard output: {t}", .{e});
            return code;
        },
    }
    deps.out.flush() catch |e| ctx.diag.err("cannot write standard output: {t}", .{e});
    return Exit.success;
}

pub fn journalctlArgs(ctx: *core.Context, deps: Deps, args: []const []const u8) u8 {
    const result = cli.journalctl.parse(ctx.gpa, args) catch |e| {
        ctx.diag.err("cannot parse arguments: {t}", .{e});
        return Exit.failure;
    };
    switch (result) {
        .ok => |req| return journalctl(ctx, deps, req),
        .err => |failure| {
            ctx.diag.err("{f}", .{FailureFmt{ .failure = failure }});
            return Exit.failure;
        },
    }
}

test {
    std.testing.refAllDecls(@This());
    inline for (.{ Session, pipeline, native, units, lifecycle, runtime, query, reload, edit, preset, pending, journal, journal_time, timers }) |m| std.testing.refAllDecls(m);
}
