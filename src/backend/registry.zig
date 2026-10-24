//! Maps a detected init to its backend. A new backend adds one `Entry`, a field in `Storage`
//! and a branch in `select`.
const std = @import("std");
const core = @import("../core/root.zig");
const InitKind = @import("../detect/kind.zig").InitKind;
const profile = @import("../detect/profile.zig");
const NullBackend = @import("null.zig");
const Dinit = @import("dinit.zig");
const Backend = @import("interface.zig").Backend;

pub const Entry = struct {
    kind: InitKind,
    name: []const u8,
};

/// Backends with a real implementation.
pub const registered = [_]Entry{
    .{ .kind = .dinit, .name = Dinit.backend_name },
};

pub fn isRegistered(kind: InitKind) bool {
    for (registered) |e| if (e.kind.sameBackend(kind)) return true;
    return false;
}

/// Backend instances live here for as long as the returned `Backend` is used.
pub const Storage = struct {
    null_backend: NullBackend = .{},
    dinit: Dinit = undefined,
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
        else => {
            storage.null_backend = .{ .detected = kind.name() };
            return storage.null_backend.backend();
        },
    }
}

test "dinit is registered and other kinds fall back to the null backend" {
    try std.testing.expect(isRegistered(.dinit));
    try std.testing.expect(!isRegistered(.runit));
    var storage: Storage = .{};
    var ctx: core.Context = undefined;
    const b = select(.runit, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("null", b.name());
    try std.testing.expectEqualStrings("runit", storage.null_backend.detected);
    const d = select(.dinit, &storage, .{ .ctx = &ctx, .profile = &profile.generic });
    try std.testing.expectEqualStrings("dinit", d.name());
    try std.testing.expect(d.caps().supervision and d.caps().soft_deps and d.caps().translates);
}
