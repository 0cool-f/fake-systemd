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
        else => {
            storage.null_backend = .{ .detected = kind.name() };
            return storage.null_backend.backend();
        },
    }
}

test "dinit, runit, s6 and s6-rc are registered and other kinds fall back to the null backend" {
    try std.testing.expect(isRegistered(.dinit));
    try std.testing.expect(isRegistered(.runit));
    try std.testing.expect(isRegistered(.s6));
    try std.testing.expect(isRegistered(.s6_rc));
    try std.testing.expect(!isRegistered(.openrc));
    var storage: Storage = .{};
    var ctx: core.Context = undefined;
    const b = select(.openrc, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("null", b.name());
    try std.testing.expectEqualStrings("openrc", storage.null_backend.detected);
    const s = select(.s6, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("s6", s.name());
    try std.testing.expect(s.caps().supervision and s.caps().per_service_logger and !s.caps().oneshot);
    const rc = select(.s6_rc, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("s6-rc", rc.name());
    try std.testing.expect(rc.caps().oneshot and rc.caps().hard_deps and !rc.caps().soft_deps);
    const d = select(.dinit, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("dinit", d.name());
    try std.testing.expect(d.caps().supervision and d.caps().soft_deps and d.caps().translates);
}
