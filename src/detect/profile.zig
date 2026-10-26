// SPDX-License-Identifier: GPL-3.0-or-later
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
    /// Vendor directory that receives services generated from vendor-tier units.
    vendor_write: ?[]const u8 = null,
    /// System-wide directories of user services.
    user_vendor: []const []const u8 = &.{},
    user_admin: []const []const u8 = &.{},
    /// Directory of boot-enable symlinks for the user instance.
    user_enable_dir: ?[]const u8 = null,
    /// Services `network.target` and `network-online.target` map to; the first existing one wins.
    network: []const []const u8 = &.{},
    network_online: []const []const u8 = &.{},
    /// Services that bring the network up, to which `network.target` and `network-online.target`
    /// become soft dependencies when they are enabled.
    network_providers: []const []const u8 = &.{},
    /// s6-rc live directory, where the services of the running database have their `servicedirs`.
    live_dir: ?[]const u8 = null,
    /// Symlink to the compiled s6-rc database that the init boots on.
    compiled: ?[]const u8 = null,
    /// Service repository of s6-rc sets, whose `sources/current` directory records the enabled services.
    repository: ?[]const u8 = null,
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

/// Services whose enabling means the network comes up; systemd-networkd has no counterpart.
const network_providers_known: []const []const u8 = &.{ "dhcpcd", "NetworkManager", "connmand", "iwd", "wpa_supplicant", "netctl" };

const dinit_generic: BackendDirs = .{
    .network_providers = network_providers_known,
    .provenance = .spec,
    .vendor = &.{ "/usr/local/lib/dinit.d", "/usr/lib/dinit.d", "/lib/dinit.d" },
    .admin = &.{"/etc/dinit.d"},
    .runtime = &.{"/run/dinit.d"},
    .user = &.{"~/.config/dinit.d"},
    .vendor_write = "/usr/lib/dinit.d",
    .user_vendor = &.{ "/usr/local/lib/dinit.d/user", "/usr/lib/dinit.d/user" },
    .user_admin = &.{"/etc/dinit.d/user"},
    .user_enable_dir = "~/.config/dinit.d/boot.d",
    .network = &.{ "network.target", "network" },
    .network_online = &.{ "network-online.target", "network-online", "network", "network.target" },
    .enable_dir = "/etc/dinit.d/boot.d",
    .enable_tool = "dinitctl",
    .boot_target = "boot",
    .native_logs = &.{"/var/log/dinit.log"},
};

/// runit keeps one service directory (`admin`) whatever the tier. Enabling links a service into
/// the runlevel directory chosen by `runsvchdir`: `sv` searches `/var/service` (Void) or
/// `/run/runit/service` (Artix), both symlinks to `/etc/runit/runsvdir/current` and so to
/// `default`, which `enable_dir` names because it also exists in a chroot. User services exist
/// where turnstile runs a runsvdir on `~/.config/service`; they are generated into
/// `~/.config/sv` and linked from there.
const runit_void: BackendDirs = .{
    .network_providers = network_providers_known,
    .provenance = .spec,
    .admin = &.{"/etc/sv"},
    .enable_dir = "/etc/runit/runsvdir/default",
    .user = &.{"~/.config/sv"},
    .user_enable_dir = "~/.config/service",
    .native_logs = &.{"/var/log/{name}/current"},
};

const runit_artix: BackendDirs = .{
    .network_providers = network_providers_known,
    .provenance = .spec,
    .admin = &.{"/etc/runit/sv"},
    .enable_dir = "/etc/runit/runsvdir/default",
    .user = &.{"~/.config/sv"},
    .user_enable_dir = "~/.config/service",
    .native_logs = &.{"/var/log/{name}/current"},
};

/// Plain s6 has no distribution convention: services live in `/etc/s6/sv`, and `/service` is
/// the persistent scan directory that `s6-svscan` runs on; enabling links a service into it.
const s6_generic: BackendDirs = .{
    .network_providers = network_providers_known,
    .provenance = .generic,
    .admin = &.{"/etc/s6/sv"},
    .enable_dir = "/service",
    .native_logs = &.{"/var/log/{name}/current"},
};

/// s6-rc without a distribution convention: the sources are compiled into `/etc/s6-rc/compiled`
/// (the default of `s6-rc-init`), a symlink to the current database, and enabling adds the
/// service to the boot bundle `default`. s6-rc looks for its live directory in `/run/s6-rc`.
const s6_rc_generic: BackendDirs = .{
    .network_providers = network_providers_known,
    .provenance = .generic,
    .admin = &.{"/etc/s6-rc/source"},
    .boot_target = "default",
    .compiled = "/etc/s6-rc/compiled",
    .live_dir = "/run/s6-rc",
    .native_logs = &.{"/var/log/{name}/current"},
};

/// Artix keeps packaged services in `/etc/s6/sv` and local ones in `/etc/s6/adminsv`, both
/// stores of the s6-rc repository `/etc/s6/repo`; the `s6` frontend (s6-frontend) syncs the
/// stores into the repository, enables services in its working set, compiles the set into the
/// boot database `/etc/s6/rc/compiled` and installs it into the live database.
const s6_rc_artix: BackendDirs = .{
    .network_providers = network_providers_known,
    .provenance = .spec,
    .vendor = &.{"/etc/s6/sv"},
    .admin = &.{"/etc/s6/adminsv"},
    .enable_tool = "s6",
    .boot_target = "default",
    .compiled = "/etc/s6/rc/compiled",
    .live_dir = "/run/s6-rc",
    .repository = "/etc/s6/repo",
    .native_logs = &.{"/var/log/{name}/current"},
};

/// OpenRC keeps scripts in `/etc/init.d` whatever the tier and enables a service with a link in
/// `/etc/runlevels/<runlevel>`, which `rc-update` writes. User sessions (0.60 and later) read
/// `/etc/user/init.d` and `~/.config/rc/init.d`, with runlevels in `~/.config/rc/runlevels`.
/// `net` is the virtual service every network provider declares with `provide`, and
/// `network-online` the one `net-online` provides; both exist on Alpine, Gentoo and Artix.
const openrc_generic: BackendDirs = .{
    .provenance = .spec,
    .admin = &.{"/etc/init.d"},
    .enable_dir = "/etc/runlevels",
    .enable_tool = "rc-update",
    .boot_target = "default",
    .user = &.{"~/.config/rc/init.d"},
    .user_admin = &.{"/etc/user/init.d"},
    .user_enable_dir = "~/.config/rc/runlevels",
    .network = &.{"net"},
    .network_online = &.{ "net", "network-online" },
    .native_logs = &.{"/var/log/rc.log"},
};

/// Alpine logs through the BusyBox syslog service, to `/var/log/messages`.
const openrc_alpine: BackendDirs = .{
    .provenance = .spec,
    .admin = &.{"/etc/init.d"},
    .enable_dir = "/etc/runlevels",
    .enable_tool = "rc-update",
    .boot_target = "default",
    .user = &.{"~/.config/rc/init.d"},
    .user_admin = &.{"/etc/user/init.d"},
    .user_enable_dir = "~/.config/rc/runlevels",
    .network = &.{"net"},
    .network_online = &.{ "net", "network-online" },
    .native_logs = &.{ "/var/log/messages", "/var/log/rc.log" },
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
        .s6 = s6_generic,
        .s6_rc = s6_rc_generic,
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

fn withOpenrc(openrc: BackendDirs) std.EnumArray(InitKind, BackendDirs) {
    var b = base();
    b.set(.openrc, openrc);
    return b;
}

fn withRunitAndS6Rc(runit: BackendDirs, s6_rc: BackendDirs) std.EnumArray(InitKind, BackendDirs) {
    var b = withRunit(runit);
    b.set(.s6_rc, s6_rc);
    return b;
}

pub const generic: Profile = .{ .id = "generic", .backends = base() };

pub const profiles = [_]Profile{
    .{ .id = "void", .match_ids = &.{"void"}, .backends = withRunit(runit_void) },
    .{ .id = "artix", .match_ids = &.{"artix"}, .backends = withRunitAndS6Rc(runit_artix, s6_rc_artix) },
    .{ .id = "debian", .match_ids = &.{ "debian", "devuan", "ubuntu" }, .backends = base(), .sysvinit = .sysvinit_debian, .schedulers = &.{"cron"} },
    .{
        .id = "redhat",
        .match_ids = &.{ "rhel", "fedora", "centos", "rocky", "almalinux", "ol" },
        .backends = base(),
        .sysvinit = .sysvinit_redhat,
        .schedulers = &.{"crond"},
    },
    .{ .id = "alpine", .match_ids = &.{"alpine"}, .backends = withOpenrc(openrc_alpine) },
    .{ .id = "chimera", .match_ids = &.{"chimera"}, .backends = base() },
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
    try testing.expectEqualStrings("/etc/runit/runsvdir/default", void_p.enable_dir.?);
    const artix = byName("artix").?.dirs(.runit);
    try testing.expectEqualStrings("/etc/runit/sv", artix.admin[0]);
    try testing.expectEqualStrings("/etc/runit/runsvdir/default", artix.enable_dir.?);
    try testing.expectEqualStrings("~/.config/service", artix.user_enable_dir.?);
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

test "dinit table carries the generation and user directories" {
    const d = generic.dirs(.dinit);
    try testing.expectEqualStrings("/usr/lib/dinit.d", d.vendor_write.?);
    try testing.expectEqualStrings("/etc/dinit.d/user", d.user_admin[0]);
    try testing.expectEqualStrings("/usr/lib/dinit.d/user", d.user_vendor[1]);
    try testing.expectEqualStrings("~/.config/dinit.d/boot.d", d.user_enable_dir.?);
    try testing.expectEqualStrings("network-online.target", d.network_online[0]);
    try testing.expectEqualStrings("network", d.network[1]);
    for ([_][]const u8{ "artix", "chimera", "alpine" }) |id| {
        try testing.expectEqualStrings("/etc/dinit.d", byName(id).?.dirs(.dinit).admin[0]);
    }
}

test "OpenRC table matches the specification" {
    const o = generic.dirs(.openrc);
    try testing.expectEqualStrings("/etc/init.d", o.admin[0]);
    try testing.expectEqualStrings("rc-update", o.enable_tool.?);
    try testing.expectEqualStrings("default", o.boot_target.?);
}

test "OpenRC tables carry the runlevel directory, user directories and virtual network services" {
    const o = generic.dirs(.openrc);
    try testing.expectEqualStrings("/etc/runlevels", o.enable_dir.?);
    try testing.expectEqualStrings("~/.config/rc/init.d", o.user[0]);
    try testing.expectEqualStrings("/etc/user/init.d", o.user_admin[0]);
    try testing.expectEqualStrings("~/.config/rc/runlevels", o.user_enable_dir.?);
    try testing.expectEqualStrings("net", o.network[0]);
    try testing.expectEqualStrings("network-online", o.network_online[1]);
    for ([_][]const u8{ "alpine", "gentoo", "artix", "debian" }) |id| {
        try testing.expectEqualStrings("/etc/init.d", byName(id).?.dirs(.openrc).admin[0]);
        try testing.expectEqualStrings("default", byName(id).?.dirs(.openrc).boot_target.?);
    }
    try testing.expectEqualStrings("/var/log/messages", byName("alpine").?.dirs(.openrc).native_logs[0]);
    try testing.expectEqualStrings("/var/log/rc.log", byName("artix").?.dirs(.openrc).native_logs[0]);
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
    try testing.expectEqual(Provenance.unset, generic.dirs(.shepherd).provenance);
    try testing.expectEqual(@as(usize, 0), generic.dirs(.s66).admin.len);
    try testing.expectEqual(Provenance.generic, generic.dirs(.finit).provenance);
}

test "every profile carries the same backend coverage" {
    for (profiles) |p| {
        for (std.enums.values(InitKind)) |k| _ = p.dirs(k);
        try testing.expect(p.schedulers.len > 0);
    }
}

test "s6 tables carry the service, scan and live directories" {
    const plain = generic.dirs(.s6);
    try testing.expectEqualStrings("/etc/s6/sv", plain.admin[0]);
    try testing.expectEqualStrings("/service", plain.enable_dir.?);
    try testing.expectEqual(Provenance.generic, plain.provenance);
    const rc = generic.dirs(.s6_rc);
    try testing.expectEqualStrings("/etc/s6-rc/source", rc.admin[0]);
    try testing.expectEqualStrings("/etc/s6-rc/compiled", rc.compiled.?);
    try testing.expectEqualStrings("/run/s6-rc", rc.live_dir.?);
    try testing.expectEqualStrings("default", rc.boot_target.?);
    try testing.expect(rc.enable_tool == null and rc.repository == null);
    for ([_][]const u8{ "alpine", "void", "chimera" }) |id| {
        try testing.expectEqualStrings("/etc/s6-rc/source", byName(id).?.dirs(.s6_rc).admin[0]);
    }
}

test "Artix drives s6-rc through the s6 frontend and its repository" {
    const artix = byName("artix").?.dirs(.s6_rc);
    try testing.expectEqual(Provenance.spec, artix.provenance);
    try testing.expectEqualStrings("/etc/s6/sv", artix.vendor[0]);
    try testing.expectEqualStrings("/etc/s6/adminsv", artix.admin[0]);
    try testing.expectEqualStrings("s6", artix.enable_tool.?);
    try testing.expectEqualStrings("/etc/s6/repo", artix.repository.?);
    try testing.expectEqualStrings("/etc/s6/rc/compiled", artix.compiled.?);
}
