// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");

pub const interface = @import("interface.zig");
pub const runner = @import("runner.zig");
pub const exec_norm = @import("exec_norm.zig");
pub const native_scan = @import("native_scan.zig");
pub const NullBackend = @import("null.zig");
pub const Fake = @import("fake.zig");
pub const Dinit = @import("dinit.zig");
pub const Runit = @import("runit.zig");
pub const S6 = @import("s6.zig");
pub const S6Rc = @import("s6_rc.zig");
pub const OpenRc = @import("openrc.zig");
pub const Sysvinit = @import("sysvinit.zig");
pub const S66 = @import("s66.zig");
pub const Busybox = @import("busybox.zig");
pub const BsdRc = @import("bsdrc.zig");
pub const Procd = @import("procd.zig");
pub const Finit = @import("finit.zig");
pub const Shepherd = @import("shepherd.zig");
pub const Nosh = @import("nosh.zig");
pub const policy = @import("policy.zig");
pub const network = @import("network.zig");
pub const registry = @import("registry.zig");

pub const Backend = interface.Backend;
pub const Runner = runner.Runner;

test {
    std.testing.refAllDecls(@This());
    _ = interface;
    _ = runner;
    _ = exec_norm;
    _ = native_scan;
    _ = NullBackend;
    _ = Fake;
    _ = Dinit;
    _ = Runit;
    _ = S6;
    _ = S6Rc;
    _ = OpenRc;
    _ = Sysvinit;
    _ = S66;
    _ = Busybox;
    _ = BsdRc;
    _ = Procd;
    _ = Finit;
    _ = Shepherd;
    _ = Nosh;
    _ = policy;
    _ = network;
    _ = registry;
}
