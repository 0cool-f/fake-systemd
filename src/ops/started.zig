// SPDX-License-Identifier: GPL-3.0-or-later
//! The end of `start` for a `Type=forking` unit that a supervisor runs through the executor.
//!
//! The supervisor reports the unit started when the executor runs, which is before the executor
//! has read `PIDFile=` and recorded the daemon as the main process, as `start` of systemd waits
//! for. The executor records itself first, so the wait ends once the recorded process is another.
const std = @import("std");
const unit = @import("../unit/root.zig");
const cli = @import("../cli/root.zig");
const backend_pkg = @import("../backend/root.zig");
const executor = @import("../exec/executor.zig");
const timespan = @import("../unit/timespan.zig");
const pipeline = @import("pipeline.zig");
const Session = @import("session.zig");

const Exit = cli.output.Exit;

const poll_ms = 100;
const default_wait_us = 90 * std.time.us_per_s;
/// Name the kernel gives the process of the executor.
const executor_comm = "fake-systemd";

fn waitMs(u: *const unit.model.Unit) u64 {
    const us = u.timeout_start_sec orelse default_wait_us;
    return if (us == timespan.infinity) std.math.maxInt(u64) else @max(us / std.time.us_per_ms, poll_ms);
}

/// True when a line of a file generated for the unit starts the executor for the main process
/// (`--exec <unit>` without `--phase`), which is not the case where the init follows `PIDFile=`
/// itself.
fn runsExecutor(plan: *const pipeline.Plan, u: *const unit.model.Unit) bool {
    const generated = switch (plan.outcome) {
        .generate => |g| g.generated,
        else => return false,
    };
    for (generated.files) |f| {
        var lines = std.mem.splitScalar(u8, f.content, '\n');
        while (lines.next()) |line| {
            if (std.mem.find(u8, line, "--exec") != null and std.mem.find(u8, line, u.name.full) != null and
                std.mem.find(u8, line, "--phase") == null) return true;
        }
    }
    return false;
}

/// Waits for the executor to have recorded the daemon of `service`, for at most
/// `TimeoutStartSec=`, and returns the exit code of the verb. A unit that is not forking with a
/// pid file, whose init follows the pid file itself, or that is not running is left alone.
pub fn awaitDaemon(s: *Session, verb: []const u8, plan: *const pipeline.Plan, service: []const u8) u8 {
    const u = &(plan.unit orelse return Exit.success);
    if (u.service_type != .forking or u.pid_file == null or s.ctx.dry_run or !runsExecutor(plan, u)) return Exit.success;
    const record = executor.execPidPath(s.ctx, u.name.full) catch return Exit.success;
    const budget = waitMs(u);
    var waited: u64 = 0;
    while (true) {
        const st = s.deps.backend.status(s.env(), service) catch return Exit.success;
        switch (st.state) {
            .failed => {
                s.ctx.diag.err("Failed to {s} {s}: it failed before the daemon was recorded", .{ verb, u.name.full });
                return Exit.failure;
            },
            .active, .activating, .reloading => {},
            else => return Exit.success,
        }
        if (backend_pkg.guard.recordedPid(s.ctx, record)) |main| {
            if (!backend_pkg.guard.hasName(s.ctx, main, executor_comm)) return Exit.success;
        }
        if (waited >= budget) {
            s.ctx.diag.err("Failed to {s} {s}: no daemon was recorded within TimeoutStartSec=", .{ verb, u.name.full });
            return Exit.failure;
        }
        s.ctx.io.sleep(.fromMilliseconds(poll_ms), .awake) catch return Exit.success;
        waited +|= poll_ms;
    }
}
