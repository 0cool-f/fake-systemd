//! Init systems fake-systemd can drive (spec §11).
const std = @import("std");

pub const InitKind = enum {
    dinit,
    runit,
    s6,
    s6_rc,
    openrc,
    /// sysvinit whose Debian or Red Hat flavour is not determined yet.
    sysvinit,
    sysvinit_debian,
    sysvinit_redhat,
    s66,
    bsd_rc,
    busybox,
    finit,
    procd,
    shepherd,
    nosh,
    unknown,

    const names = [_][]const u8{
        "dinit", "runit",  "s6",      "s6-rc", "openrc", "sysvinit", "sysvinit-debian", "sysvinit-redhat",
        "66",    "bsd-rc", "busybox", "finit", "procd",  "shepherd", "nosh",            "unknown",
    };

    comptime {
        std.debug.assert(names.len == std.meta.fieldNames(InitKind).len);
    }

    pub fn name(kind: InitKind) []const u8 {
        return names[@backingInt(kind)];
    }

    /// Accepts the canonical names plus `s66` and `none`.
    pub fn fromName(text: []const u8) ?InitKind {
        for (names, 0..) |n, i| {
            if (std.mem.eql(u8, n, text)) return @fromBackingInt(@intCast(i));
        }
        if (std.mem.eql(u8, text, "s66")) return .s66;
        if (std.mem.eql(u8, text, "none")) return .unknown;
        return null;
    }

    pub fn isSysvinit(kind: InitKind) bool {
        return kind == .sysvinit or kind == .sysvinit_debian or kind == .sysvinit_redhat;
    }

    /// True when both kinds are the same backend, ignoring the sysvinit flavour.
    pub fn sameBackend(a: InitKind, b: InitKind) bool {
        return a == b or (a.isSysvinit() and b.isSysvinit());
    }
};

test "names round-trip" {
    for (std.enums.values(InitKind)) |k| {
        try std.testing.expectEqual(k, InitKind.fromName(k.name()).?);
    }
    try std.testing.expectEqualStrings("s6-rc", InitKind.s6_rc.name());
    try std.testing.expectEqualStrings("66", InitKind.s66.name());
}

test "aliases and rejection" {
    try std.testing.expectEqual(InitKind.s66, InitKind.fromName("s66").?);
    try std.testing.expectEqual(InitKind.unknown, InitKind.fromName("none").?);
    try std.testing.expect(InitKind.fromName("systemd") == null);
    try std.testing.expect(InitKind.fromName("") == null);
    try std.testing.expect(InitKind.fromName("s6_rc") == null);
}

test "sysvinit flavours are the same backend" {
    try std.testing.expect(InitKind.sysvinit.sameBackend(.sysvinit_debian));
    try std.testing.expect(InitKind.sysvinit_redhat.sameBackend(.sysvinit_debian));
    try std.testing.expect(InitKind.dinit.sameBackend(.dinit));
    try std.testing.expect(!InitKind.s6.sameBackend(.s6_rc));
    try std.testing.expect(!InitKind.openrc.sameBackend(.sysvinit));
}
