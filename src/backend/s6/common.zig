// SPDX-License-Identifier: GPL-3.0-or-later
//! Logic that the s6 and s6-rc backends share: program lookup, the identity a generated script
//! switches to, and how the dependencies of a unit resolve to services.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../core/root.zig");
const profile = @import("../../detect/profile.zig");
const model = @import("../../unit/model.zig");
const name_mod = @import("../../unit/name.zig");
const resolve = @import("../../unit/resolve.zig");
const marker = @import("../../index/marker.zig");
const interface = @import("../interface.zig");
const policy = @import("../policy.zig");
const network = @import("../network.zig");
const layout = @import("layout.zig");
const render = @import("render.zig");
const shell = @import("../shell.zig");

/// What `run`, `up` and `down` express without the executor: `Environment=` and `UMask=` as
/// shell or execline lines, `Limit*=` with plain numbers as `s6-softlimit`. `Group=` and
/// `SupplementaryGroups=` need the executor, because `s6-setuidgid` keeps only the groups of
/// the user.
pub fn nativeSupport() policy.Native {
    const names = comptime render.nativeLimitNames();
    return .{
        .environment = true,
        .umask = true,
        .limits = &names,
        .limits_numeric = true,
    };
}

const command_dirs = [_][]const u8{ "/usr/local/bin", "/usr/bin", "/bin" };

pub const Base = struct {
    ctx: *core.Context,
    dirs: *const profile.BackendDirs,
    flavor: layout.Flavor,
    /// Replaces the check of which services are enabled when the network targets are mapped; for
    /// tests.
    enabled_override: ?[]const []const u8 = null,

    pub fn exists(self: Base, service: []const u8) !bool {
        return switch (self.flavor) {
            .plain => (try layout.locatePlain(self.ctx, self.dirs, service)) != null,
            .rc => (try layout.locateRc(self.ctx, self.dirs, service)) != null,
        };
    }

    /// `name` found in the standard directories, or null when none holds it.
    pub fn findProgram(self: Base, name: []const u8) !?[]const u8 {
        for (command_dirs) |dir| {
            const path = try std.fs.path.join(self.ctx.gpa, &.{ dir, name });
            if (self.ctx.fs.exists(path)) return path;
        }
        return null;
    }

    /// `name` resolved against the standard directories, or `fallback` when none holds it.
    pub fn resolveProgram(self: Base, name: []const u8, fallback: []const u8) ![]const u8 {
        return (try self.findProgram(name)) orelse fallback;
    }

    pub fn commandWords(self: Base, cmd: model.Command) ![]const []const u8 {
        const words = try self.ctx.gpa.dupe([]const u8, cmd.words);
        if (std.mem.findScalar(u8, words[0], '/') == null) words[0] = try self.resolveProgram(words[0], words[0]);
        return words;
    }

    // ---- identity -------------------------------------------------------------------------

    fn accountKnown(self: Base, file: []const u8, account: []const u8) bool {
        if (account.len > 0 and std.ascii.isDigit(account[0])) return true;
        const content = self.ctx.fs.readFileAlloc(self.ctx.gpa, file, 1 << 20) catch return false;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            if (std.mem.eql(u8, line[0..colon], account)) return true;
        }
        return false;
    }

    /// True when the static executor can switch to the unit's user and groups from `/etc/passwd`
    /// and `/etc/group`; it then applies the user's supplementary groups as `initgroups` does.
    pub fn executorResolves(self: Base, u: *const model.Unit) bool {
        if (u.scope == .user) return false;
        const user = u.user orelse return false;
        if (!self.accountKnown("/etc/passwd", user)) return false;
        if (u.group) |g| if (!self.accountKnown("/etc/group", g)) return false;
        for (u.supplementary_groups) |g| if (!self.accountKnown("/etc/group", g)) return false;
        return true;
    }

    /// True when a script cannot carry the unit's settings itself and the executor has to.
    /// Without `setpriv`, `s6-setuidgid` takes account names, never numbers, and keeps only the
    /// groups of the user; groups need a user.
    pub fn nativeBlocked(u: *const model.Unit, have_setpriv: bool) bool {
        if (!have_setpriv) {
            if (u.user) |user| if (numeric(user)) return true;
            if (u.group != null or u.supplementary_groups.len > 0) return true;
        }
        if ((u.group != null or u.supplementary_groups.len > 0) and u.user == null) return true;
        for (u.environment) |e| if (!validEnvName(e.name)) return true;
        return false;
    }

    fn plainAccounts(u: *const model.Unit) bool {
        var plain = render.plainAccount(u.user.?);
        if (u.group) |g| plain = plain and render.plainAccount(g);
        for (u.supplementary_groups) |g| plain = plain and render.plainAccount(g);
        return plain;
    }

    /// An account the executor cannot resolve (LDAP, sssd) is passed to it as numeric ids that the
    /// scripts look up, wherever they run it; the executor stays root and switches itself.
    pub fn numericFor(self: Base, u: *const model.Unit, use_executor: bool) !?shell.Numeric {
        if (u.scope == .user) return null;
        const user = u.user orelse return null;
        if (self.executorResolves(u)) return null;
        if (!plainAccounts(u)) {
            if (!use_executor) return null;
            self.ctx.diag.err("{s}: User=, Group= and SupplementaryGroups= must be plain names to be looked up by the system libc", .{u.name.full});
            return error.Unsupported;
        }
        return .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups };
    }

    /// How a script switches to the account of a native command that the executor cannot resolve
    /// (LDAP, sssd). `setpriv` is dynamically linked, so the system libc finds the user and
    /// `--init-groups` applies its groups; `s6-setuidgid` finds the user the same way but takes
    /// the supplementary groups from an enumeration of the group database, which such a
    /// directory may not offer.
    pub fn identityFor(self: Base, u: *const model.Unit, have_setpriv: bool, use_executor: bool) !?render.Identity {
        if (u.scope == .user or use_executor) return null;
        const user = u.user orelse return null;
        if (self.executorResolves(u)) return null;
        const plain = plainAccounts(u);
        if (have_setpriv and plain) return .{ .setpriv = .{ .user = user, .group = u.group, .supplementary = u.supplementary_groups } };
        if (!have_setpriv) {
            self.ctx.diag.warn("{s}: setpriv is not installed, s6-setuidgid switches to {s} with the supplementary groups the system enumerates", .{ u.name.full, user });
        }
        return .{ .setuidgid = user };
    }

    // ---- dependencies ---------------------------------------------------------------------

    fn networkService(self: Base, target: []const u8) !?[]const u8 {
        const candidates = if (std.mem.eql(u8, target, "network-online.target"))
            self.dirs.network_online
        else if (std.mem.eql(u8, target, "network.target"))
            self.dirs.network
        else
            return null;
        for (candidates) |c| if (try self.exists(c)) return c;
        return null;
    }

    /// Name of the service a dependency refers to, or null when it cannot be a service: targets
    /// (except the network ones), other unit types, and units that are neither a service of the
    /// init nor a systemd unit that can be translated.
    pub fn mapDependency(self: Base, own: []const u8, dep: []const u8, resolutions: []const interface.Dep) !?[]const u8 {
        const gpa = self.ctx.gpa;
        const n = name_mod.parse(gpa, dep) catch return null;
        switch (n.kind) {
            .target => return self.networkService(n.full),
            .service => {},
            else => return null,
        }
        for (resolutions) |r| if (std.mem.eql(u8, r.unit, n.full)) return r.service;
        if (n.isTemplate() or std.mem.startsWith(u8, n.prefix, "systemd-")) return null;
        const svc = try layout.serviceName(gpa, n);
        if (std.mem.eql(u8, svc, own)) return null;
        if (try self.exists(svc)) return svc;
        const resolved = resolve.resolve(gpa, self.ctx.fs.*, .{ .scope = self.ctx.scope, .xdg_config_home = self.ctx.xdg_config_home }, n) catch return null;
        return if (resolved.state == .found) svc else null;
    }

    pub fn mapList(self: Base, own: []const u8, resolutions: []const interface.Dep, deps: []const []const u8, exclude: []const []const u8, out: *std.ArrayList([]const u8)) !void {
        for (deps) |dep| {
            const mapped = (try self.mapDependency(own, dep, resolutions)) orelse continue;
            if (contains(exclude, mapped) or contains(out.items, mapped)) continue;
            try out.append(self.ctx.gpa, mapped);
        }
    }

    /// Hard and soft dependencies of `u`, with the enabled network providers added as soft ones
    /// when the unit mentions a network target.
    pub fn dependencies(self: Base, own: []const u8, u: *const model.Unit, resolutions: []const interface.Dep, enabled: network.Enabled) !Dependencies {
        var needs: std.ArrayList([]const u8) = .empty;
        var wants: std.ArrayList([]const u8) = .empty;
        try self.mapList(own, resolutions, u.requires, &.{}, &needs);
        try self.mapList(own, resolutions, u.binds_to, &.{}, &needs);
        try self.mapList(own, resolutions, u.wants, needs.items, &wants);
        if (network.mentions(u)) {
            for (try network.enabledProviders(self.ctx.gpa, self.dirs.network_providers, own, enabled)) |p| {
                if (!contains(needs.items, p) and !contains(wants.items, p)) try wants.append(self.ctx.gpa, p);
            }
        }
        return .{ .hard = needs.items, .soft = wants.items };
    }
};

pub const Dependencies = struct {
    hard: []const []const u8,
    soft: []const []const u8,
};

pub fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

fn numeric(name: []const u8) bool {
    return name.len > 0 and std.ascii.isDigit(name[0]);
}

fn validEnvName(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// The unit recorded in the marker of `content`, null for a file fake-systemd did not generate.
pub fn unitOf(content: []const u8) ?[]const u8 {
    const parsed = marker.parse(content) orelse return null;
    return parsed.marker.unit;
}

const testing = std.testing;

fn unitWith(a: Allocator, user: ?[]const u8, group: ?[]const u8, supp: []const []const u8) !model.Unit {
    var u: model.Unit = .{ .name = try name_mod.parse(a, "foo.service"), .scope = .system };
    u.user = user;
    u.group = group;
    u.supplementary_groups = supp;
    return u;
}

test "without setpriv, accounts s6-setuidgid cannot take block the script" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(!Base.nativeBlocked(&try unitWith(a, "svc", null, &.{}), false));
    try testing.expect(Base.nativeBlocked(&try unitWith(a, "1500", null, &.{}), false));
    try testing.expect(Base.nativeBlocked(&try unitWith(a, "svc", "grp", &.{}), false));
    try testing.expect(Base.nativeBlocked(&try unitWith(a, "svc", null, &.{"extra"}), false));
    try testing.expect(!Base.nativeBlocked(&try unitWith(a, "1500", "grp", &.{"extra"}), true));
    try testing.expect(Base.nativeBlocked(&try unitWith(a, null, "grp", &.{}), true));
}

test "environment names a shell cannot export block the script" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var u = try unitWith(arena.allocator(), null, null, &.{});
    u.environment = &.{.{ .name = "OK_1", .value = "x" }};
    try testing.expect(!Base.nativeBlocked(&u, true));
    u.environment = &.{.{ .name = "1BAD", .value = "x" }};
    try testing.expect(Base.nativeBlocked(&u, true));
    u.environment = &.{.{ .name = "a-b", .value = "x" }};
    try testing.expect(Base.nativeBlocked(&u, true));
}

test "native support names the s6-softlimit settings" {
    const s = nativeSupport();
    try testing.expect(s.environment and s.umask and s.limits_numeric and !s.group);
    try testing.expect(contains(s.limits, "LimitNOFILE"));
    try testing.expect(contains(s.limits, "LimitCPU"));
}
