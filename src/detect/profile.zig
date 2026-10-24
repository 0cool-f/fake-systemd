//! Distribution profiles (spec §4.3): per-backend directory tables and conventions, selected
//! from os-release `ID` then `ID_LIKE`. Values marked `.spec` are stated in the specification;
//! every other table entry is a generic default that has not been checked against a distribution.
const std = @import("std");
const InitKind = @import("kind.zig").InitKind;
const OsRelease = @import("osrelease.zig").OsRelease;

pub const Provenance = enum {
    /// Directories and mechanism are stated in the specification for this backend and profile.
    spec,
    /// Generic default.
    generic,
    /// Nothing is known for this backend; all fields are empty.
    unset,
};

/// Paths starting with `~/` are relative to the user's home. `{name}` in log patterns stands
/// for the service name.
pub const BackendDirs = struct {
    provenance: Provenance = .unset,
    /// Vendor (package-provided) service directories, lowest priority first as listed.
    vendor: []const []const u8 = &.{},
    /// System administrator service directories.
    admin: []const []const u8 = &.{},
    /// Volatile service directories (`--runtime`).
    runtime: []const []const u8 = &.{},
    /// User-scope service directories.
    user: []const []const u8 = &.{},
    /// Directory of boot-enable symlinks; null when enabling goes through `enable_tool`.
    enable_dir: ?[]const u8 = null,
    /// Directory of boot-enable symlinks that does not survive a reboot.
    runtime_enable_dir: ?[]const u8 = null,
    /// Command that enables and disables services.
    enable_tool: ?[]const u8 = null,
    /// Boot service (dinit) or runlevel (OpenRC) that enabling attaches to.
    boot_target: ?[]const u8 = null,
    /// Places where native services of this backend log.
    native_logs: []const []const u8 = &.{},
};

pub const Profile = struct {
    id: []const u8,
    /// os-release `ID` values (and `ID_LIKE` entries) this profile applies to.
    match_ids: []const []const u8 = &.{},
    backends: std.EnumArray(InitKind, BackendDirs),
    /// Service that `network.target` and `network-online.target` map to, when known.
    network_service: ?[]const u8 = null,
    /// Names of cron-like schedulers expected on the system.
    schedulers: []const []const u8 = &.{ "crond", "cron" },
    /// Flavour used when sysvinit is detected without a distinguishing signal.
    sysvinit: InitKind = .sysvinit,

    pub fn dirs(p: *const Profile, kind: InitKind) *const BackendDirs {
        return p.backends.getPtrConst(kind);
    }

    /// Resolves the generic `sysvinit` kind to this profile's flavour; other kinds pass through.
    pub fn refine(p: *const Profile, kind: InitKind) InitKind {
        return if (kind == .sysvinit) p.sysvinit else kind;
    }
};

const sysv_dirs: []const []const u8 = &.{"/etc/init.d"};

const dinit_generic: BackendDirs = .{
    .provenance = .spec,
    .vendor = &.{ "/usr/local/lib/dinit.d", "/usr/lib/dinit.d", "/lib/dinit.d" },
    .admin = &.{"/etc/dinit.d"},
    .runtime = &.{"/run/dinit.d"},
    .user = &.{"~/.config/dinit.d"},
    .enable_dir = "/etc/dinit.d/boot.d",
    .enable_tool = "dinitctl",
    .boot_target = "boot",
    .native_logs = &.{"/var/log/dinit.log"},
};

const runit_void: BackendDirs = .{
    .provenance = .spec,
    .admin = &.{"/etc/sv"},
    .enable_dir = "/var/service",
    .native_logs = &.{"/var/log/{name}/current"},
};

const runit_artix: BackendDirs = .{
    .provenance = .spec,
    .admin = &.{"/etc/runit/sv"},
    .enable_dir = "/run/runit/service",
    .native_logs = &.{"/var/log/{name}/current"},
};

const openrc_generic: BackendDirs = .{
    .provenance = .spec,
    .admin = &.{"/etc/init.d"},
    .enable_tool = "rc-update",
    .boot_target = "default",
    .native_logs = &.{"/var/log/rc.log"},
};

const sysv_debian: BackendDirs = .{
    .provenance = .spec,
    .admin = sysv_dirs,
    .enable_tool = "update-rc.d",
    .native_logs = &.{ "/var/log/syslog", "/var/log/daemon.log" },
};

const sysv_redhat: BackendDirs = .{
    .provenance = .spec,
    .admin = sysv_dirs,
    .enable_tool = "chkconfig",
    .native_logs = &.{"/var/log/messages"},
};

const finit_generic: BackendDirs = .{
    .provenance = .generic,
    .admin = &.{"/etc/finit.d"},
};

const procd_generic: BackendDirs = .{
    .provenance = .generic,
    .admin = sysv_dirs,
};

const bsd_rc_generic: BackendDirs = .{
    .provenance = .generic,
    .admin = &.{"/etc/rc.d"},
};

/// Backends whose tables are the same on every profile.
fn base() std.EnumArray(InitKind, BackendDirs) {
    return .initDefault(.{}, .{
        .dinit = dinit_generic,
        .runit = runit_void,
        .openrc = openrc_generic,
        .sysvinit = .{ .provenance = .generic, .admin = sysv_dirs },
        .sysvinit_debian = sysv_debian,
        .sysvinit_redhat = sysv_redhat,
        .finit = finit_generic,
        .procd = procd_generic,
        .bsd_rc = bsd_rc_generic,
    });
}

fn withRunit(runit: BackendDirs) std.EnumArray(InitKind, BackendDirs) {
    var b = base();
    b.set(.runit, runit);
    return b;
}

pub const generic: Profile = .{ .id = "generic", .backends = base() };

pub const profiles = [_]Profile{
    .{ .id = "void", .match_ids = &.{"void"}, .backends = withRunit(runit_void) },
    .{ .id = "artix", .match_ids = &.{"artix"}, .backends = withRunit(runit_artix) },
    .{ .id = "debian", .match_ids = &.{ "debian", "devuan", "ubuntu" }, .backends = base(), .sysvinit = .sysvinit_debian, .schedulers = &.{"cron"} },
    .{
        .id = "redhat",
        .match_ids = &.{ "rhel", "fedora", "centos", "rocky", "almalinux", "ol" },
        .backends = base(),
        .sysvinit = .sysvinit_redhat,
        .schedulers = &.{"crond"},
    },
    .{ .id = "alpine", .match_ids = &.{"alpine"}, .backends = base() },
    .{ .id = "gentoo", .match_ids = &.{"gentoo"}, .backends = base() },
    .{ .id = "openwrt", .match_ids = &.{"openwrt"}, .backends = base() },
    .{ .id = "slackware", .match_ids = &.{"slackware"}, .backends = base() },
    .{ .id = "guix", .match_ids = &.{"guix"}, .backends = base() },
    .{ .id = "obarun", .match_ids = &.{"obarun"}, .backends = base() },
};

/// Profile named `id` (as accepted by `FAKE_SYSTEMD_PROFILE` / `Profile=`); `generic` is included.
pub fn byName(id: []const u8) ?*const Profile {
    if (std.mem.eql(u8, id, generic.id)) return &generic;
    for (&profiles) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

fn byMatchId(id: []const u8) ?*const Profile {
    for (&profiles) |*p| {
        for (p.match_ids) |m| {
            if (std.mem.eql(u8, m, id)) return p;
        }
    }
    return null;
}

/// Picks the profile for `os`: `ID` first, then each `ID_LIKE` entry in order, else `generic`.
pub fn select(os: OsRelease) *const Profile {
    if (byMatchId(os.id)) |p| return p;
    for (os.id_like) |like| {
        if (byMatchId(like)) |p| return p;
    }
    return &generic;
}

const testing = std.testing;
const osrelease = @import("osrelease.zig");

fn selectFor(arena: *std.heap.ArenaAllocator, content: []const u8) !*const Profile {
    return select(try osrelease.parse(arena.allocator(), content));
}

test "selection by ID" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("void", (try selectFor(&arena, "ID=void\n")).id);
    try testing.expectEqualStrings("artix", (try selectFor(&arena, "ID=artix\nID_LIKE=arch\n")).id);
    try testing.expectEqualStrings("debian", (try selectFor(&arena, "ID=devuan\n")).id);
    try testing.expectEqualStrings("redhat", (try selectFor(&arena, "ID=fedora\n")).id);
}

test "ID wins over ID_LIKE" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("void", (try selectFor(&arena, "ID=void\nID_LIKE=debian\n")).id);
}

test "ID_LIKE is consulted in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("debian", (try selectFor(&arena, "ID=mint\nID_LIKE=\"ubuntu debian\"\n")).id);
    try testing.expectEqualStrings("redhat", (try selectFor(&arena, "ID=rocky2\nID_LIKE=\"unknown rhel fedora\"\n")).id);
    try testing.expectEqualStrings("void", (try selectFor(&arena, "ID=voidish\nID_LIKE=\"void debian\"\n")).id);
}

test "unknown distribution and missing os-release use the generic profile" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("generic", (try selectFor(&arena, "ID=plan9\n")).id);
    try testing.expectEqualStrings("generic", select(.{}).id);
}

test "byName finds profiles and generic" {
    try testing.expectEqualStrings("void", byName("void").?.id);
    try testing.expectEqualStrings("generic", byName("generic").?.id);
    try testing.expect(byName("nope") == null);
    for (&profiles) |*p| try testing.expect(byName(p.id).? == p);
}

test "runit differs between Void and Artix" {
    const void_p = byName("void").?.dirs(.runit);
    try testing.expectEqualStrings("/etc/sv", void_p.admin[0]);
    try testing.expectEqualStrings("/var/service", void_p.enable_dir.?);
    const artix = byName("artix").?.dirs(.runit);
    try testing.expectEqualStrings("/etc/runit/sv", artix.admin[0]);
    try testing.expectEqualStrings("/run/runit/service", artix.enable_dir.?);
    try testing.expectEqual(Provenance.spec, artix.provenance);
}

test "dinit table matches the specification" {
    const d = generic.dirs(.dinit);
    try testing.expectEqualStrings("/etc/dinit.d", d.admin[0]);
    try testing.expectEqualStrings("/run/dinit.d", d.runtime[0]);
    try testing.expectEqualStrings("/usr/local/lib/dinit.d", d.vendor[0]);
    try testing.expectEqualStrings("~/.config/dinit.d", d.user[0]);
    try testing.expectEqualStrings("/etc/dinit.d/boot.d", d.enable_dir.?);
    try testing.expectEqualStrings("boot", d.boot_target.?);
    try testing.expectEqualStrings("dinitctl", d.enable_tool.?);
}

test "OpenRC table matches the specification" {
    const o = generic.dirs(.openrc);
    try testing.expectEqualStrings("/etc/init.d", o.admin[0]);
    try testing.expectEqualStrings("rc-update", o.enable_tool.?);
    try testing.expectEqualStrings("default", o.boot_target.?);
}

test "sysvinit flavours and profile refinement" {
    try testing.expectEqualStrings("update-rc.d", generic.dirs(.sysvinit_debian).enable_tool.?);
    try testing.expectEqualStrings("chkconfig", generic.dirs(.sysvinit_redhat).enable_tool.?);
    try testing.expectEqual(InitKind.sysvinit_debian, byName("debian").?.refine(.sysvinit));
    try testing.expectEqual(InitKind.sysvinit_redhat, byName("redhat").?.refine(.sysvinit));
    try testing.expectEqual(InitKind.sysvinit, generic.refine(.sysvinit));
    try testing.expectEqual(InitKind.dinit, byName("debian").?.refine(.dinit));
}

test "backends without stated data are unset" {
    try testing.expectEqual(Provenance.unset, generic.dirs(.s6).provenance);
    try testing.expectEqual(Provenance.unset, generic.dirs(.shepherd).provenance);
    try testing.expectEqual(@as(usize, 0), generic.dirs(.s6_rc).admin.len);
    try testing.expectEqual(Provenance.generic, generic.dirs(.finit).provenance);
}

test "every profile carries the same backend coverage" {
    for (profiles) |p| {
        for (std.enums.values(InitKind)) |k| _ = p.dirs(k);
        try testing.expect(p.schedulers.len > 0);
    }
}
