// SPDX-License-Identifier: GPL-3.0-or-later
//! Maps a detected init to its backend. A new backend adds one `Entry`, a field in `Storage`
//! and a branch in `select`.
const std = @import("std");
const core = @import("../core/root.zig");
const InitKind = @import("../detect/kind.zig").InitKind;
const profile = @import("../detect/profile.zig");
const NullBackend = @import("null.zig");
const Dinit = @import("dinit.zig");
const Runit = @import("runit.zig");
const S6 = @import("s6.zig");
const S6Rc = @import("s6_rc.zig");
const OpenRc = @import("openrc.zig");
const Sysvinit = @import("sysvinit.zig");
const S66 = @import("s66.zig");
const Busybox = @import("busybox.zig");
const BsdRc = @import("bsdrc.zig");
const Procd = @import("procd.zig");
const Finit = @import("finit.zig");
const Shepherd = @import("shepherd.zig");
const Nosh = @import("nosh.zig");
const Backend = @import("interface.zig").Backend;

pub const Entry = struct {
    kind: InitKind,
    name: []const u8,
};

/// Backends with a real implementation.
pub const registered = [_]Entry{
    .{ .kind = .dinit, .name = Dinit.backend_name },
    .{ .kind = .runit, .name = Runit.backend_name },
    .{ .kind = .s6, .name = S6.backend_name },
    .{ .kind = .s6_rc, .name = S6Rc.backend_name },
    .{ .kind = .openrc, .name = OpenRc.backend_name },
    .{ .kind = .sysvinit, .name = Sysvinit.backend_name },
    .{ .kind = .s66, .name = S66.backend_name },
    .{ .kind = .busybox, .name = Busybox.backend_name },
    .{ .kind = .bsd_rc, .name = BsdRc.backend_name },
    .{ .kind = .procd, .name = Procd.backend_name },
    .{ .kind = .finit, .name = Finit.backend_name },
    .{ .kind = .shepherd, .name = Shepherd.backend_name },
    .{ .kind = .nosh, .name = Nosh.backend_name },
};

pub fn isRegistered(kind: InitKind) bool {
    for (registered) |e| if (e.kind.sameBackend(kind)) return true;
    return false;
}

/// Backend instances live here for as long as the returned `Backend` is used.
pub const Storage = struct {
    null_backend: NullBackend = .{},
    dinit: Dinit = undefined,
    runit: Runit = undefined,
    s6: S6 = undefined,
    s6_rc: S6Rc = undefined,
    openrc: OpenRc = undefined,
    sysvinit: Sysvinit = undefined,
    s66: S66 = undefined,
    busybox: Busybox = undefined,
    bsd_rc: BsdRc = undefined,
    procd: Procd = undefined,
    finit: Finit = undefined,
    shepherd: Shepherd = undefined,
    nosh: Nosh = undefined,
};

/// What a real backend needs to be built.
pub const Setup = struct {
    ctx: *core.Context,
    profile: *const profile.Profile,
};

/// Backend for `kind`; unregistered kinds use the null backend.
pub fn select(kind: InitKind, storage: *Storage, setup: Setup) Backend {
    switch (kind) {
        .dinit => {
            storage.dinit = .init(setup.ctx, setup.profile.dirs(.dinit));
            return storage.dinit.backend();
        },
        .runit => {
            storage.runit = .init(setup.ctx, setup.profile.dirs(.runit));
            return storage.runit.backend();
        },
        .s6 => {
            storage.s6 = .init(setup.ctx, setup.profile.dirs(.s6));
            return storage.s6.backend();
        },
        .s6_rc => {
            storage.s6_rc = .init(setup.ctx, setup.profile.dirs(.s6_rc));
            return storage.s6_rc.backend();
        },
        .openrc => {
            storage.openrc = .init(setup.ctx, setup.profile.dirs(.openrc));
            return storage.openrc.backend();
        },
        .s66 => {
            storage.s66 = .init(setup.ctx, setup.profile.dirs(.s66));
            return storage.s66.backend();
        },
        .busybox => {
            storage.busybox = .init(setup.ctx, setup.profile.dirs(.busybox));
            return storage.busybox.backend();
        },
        .sysvinit, .sysvinit_debian, .sysvinit_redhat => {
            const variant = Sysvinit.variantFor(setup.ctx, kind);
            const dirs = setup.profile.dirs(if (variant == .redhat) .sysvinit_redhat else .sysvinit_debian);
            storage.sysvinit = .init(setup.ctx, dirs, variant);
            return storage.sysvinit.backend();
        },
        .bsd_rc => {
            storage.bsd_rc = .init(setup.ctx, setup.profile.dirs(.bsd_rc));
            return storage.bsd_rc.backend();
        },
        .procd => {
            storage.procd = .init(setup.ctx, setup.profile.dirs(.procd));
            return storage.procd.backend();
        },
        .finit => {
            storage.finit = .init(setup.ctx, setup.profile.dirs(.finit));
            return storage.finit.backend();
        },
        .shepherd => {
            storage.shepherd = .init(setup.ctx, setup.profile.dirs(.shepherd));
            return storage.shepherd.backend();
        },
        .nosh => {
            storage.nosh = .init(setup.ctx, setup.profile.dirs(.nosh));
            return storage.nosh.backend();
        },
        else => {
            storage.null_backend = .{ .detected = kind.name() };
            return storage.null_backend.backend();
        },
    }
}

test "dinit, runit, s6, s6-rc, OpenRC and sysvinit are registered and other kinds fall back to the null backend" {
    try std.testing.expect(isRegistered(.dinit));
    try std.testing.expect(isRegistered(.runit));
    try std.testing.expect(isRegistered(.s6));
    try std.testing.expect(isRegistered(.s6_rc));
    try std.testing.expect(isRegistered(.openrc));
    try std.testing.expect(isRegistered(.sysvinit) and isRegistered(.sysvinit_debian) and isRegistered(.sysvinit_redhat));
    try std.testing.expect(!isRegistered(.unknown));
    var storage: Storage = .{};
    var ctx: core.Context = undefined;
    const b = select(.unknown, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("null", b.name());
    try std.testing.expectEqualStrings("unknown", storage.null_backend.detected);
    const fi = select(.finit, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("finit", fi.name());
    try std.testing.expect(fi.caps().hard_deps and fi.caps().supervision and fi.caps().oneshot and !fi.caps().soft_deps and !fi.caps().per_service_logger);
    const sh = select(.shepherd, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("shepherd", sh.name());
    try std.testing.expect(sh.caps().hard_deps and sh.caps().user_services and sh.caps().oneshot and !sh.caps().soft_deps);
    const nh = select(.nosh, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("nosh", nh.name());
    try std.testing.expect(nh.caps().hard_deps and nh.caps().soft_deps and nh.caps().oneshot and !nh.caps().user_services);
    const s = select(.s6, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("s6", s.name());
    try std.testing.expect(s.caps().supervision and s.caps().per_service_logger and !s.caps().oneshot);
    const rc = select(.s6_rc, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("s6-rc", rc.name());
    try std.testing.expect(rc.caps().oneshot and rc.caps().hard_deps and !rc.caps().soft_deps);
    const d = select(.dinit, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("dinit", d.name());
    try std.testing.expect(d.caps().supervision and d.caps().soft_deps and d.caps().translates);
    const sv = select(.sysvinit_redhat, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("sysvinit", sv.name());
    try std.testing.expect(sv.caps().hard_deps and sv.caps().soft_deps and sv.caps().ordering and !sv.caps().supervision and !sv.caps().restart_policy);
    try std.testing.expectEqual(Sysvinit.Variant.redhat, storage.sysvinit.variant);
}

test "66 is registered with its own capabilities" {
    try std.testing.expect(isRegistered(.s66));
    var storage: Storage = .{};
    var ctx: core.Context = undefined;
    const b = select(.s66, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("66", b.name());
    try std.testing.expect(b.caps().hard_deps and b.caps().supervision and b.caps().oneshot and b.caps().user_services);
    try std.testing.expect(!b.caps().soft_deps and !b.caps().per_service_logger and !b.caps().runtime_dir);
}

test "BusyBox init is registered" {
    try std.testing.expect(isRegistered(.busybox));
}
