//! Maps a detected init to its backend. Phase 1 registers no real init: every kind falls back
//! to the null backend. A new backend adds one `Entry` and a constructor here.
const std = @import("std");
const InitKind = @import("../detect/kind.zig").InitKind;
const NullBackend = @import("null.zig");
const Backend = @import("interface.zig").Backend;

pub const Entry = struct {
    kind: InitKind,
    name: []const u8,
};

/// Backends with a real implementation.
pub const registered = [_]Entry{};

pub fn isRegistered(kind: InitKind) bool {
    for (registered) |e| if (e.kind.sameBackend(kind)) return true;
    return false;
}

/// Backend for `kind`; unregistered kinds use the null backend stored in `fallback`.
pub fn select(kind: InitKind, fallback: *NullBackend) Backend {
    fallback.* = .{ .detected = kind.name() };
    return fallback.backend();
}

test "no init is registered yet" {
    try std.testing.expect(!isRegistered(.dinit));
    var fallback: NullBackend = .{};
    const b = select(.dinit, &fallback);
    try std.testing.expectEqualStrings("null", b.name());
    try std.testing.expectEqualStrings("dinit", fallback.detected);
}
