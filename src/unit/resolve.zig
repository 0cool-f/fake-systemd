//! Unit resolution (§6.1): lookup paths per scope, fragment, masks, aliases, drop-ins and
//! template fallback. All filesystem access goes through `Fs`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Fs = @import("../core/Fs.zig");
const types = @import("../core/types.zig");
const name_mod = @import("name.zig");
const Name = name_mod.Name;

pub const Scope = types.Scope;
pub const Tier = types.Tier;

pub const max_unit_file_size = 1 << 20;

pub const Options = struct {
    scope: Scope,
    /// Base of the personal user directory (`<xdg_config_home>/systemd/user`); user scope only.
    xdg_config_home: []const u8 = "/root/.config",
};

pub const SearchDir = struct {
    path: []const u8,
    tier: Tier,
};

const system_dirs = [_]SearchDir{
    .{ .path = "/etc/systemd/system", .tier = .admin },
    .{ .path = "/run/systemd/system", .tier = .runtime },
    .{ .path = "/usr/local/lib/systemd/system", .tier = .vendor },
    .{ .path = "/usr/lib/systemd/system", .tier = .vendor },
    .{ .path = "/lib/systemd/system", .tier = .vendor },
};

const user_dirs = [_]SearchDir{
    .{ .path = "/etc/systemd/user", .tier = .admin },
    .{ .path = "/usr/local/lib/systemd/user", .tier = .vendor },
    .{ .path = "/usr/lib/systemd/user", .tier = .vendor },
};

/// Lookup directories in priority order, highest first.
pub fn searchDirs(gpa: Allocator, opts: Options) Allocator.Error![]const SearchDir {
    switch (opts.scope) {
        .system => return gpa.dupe(SearchDir, &system_dirs),
        .user => {
            var dirs: std.ArrayList(SearchDir) = .empty;
            const personal = try std.fs.path.join(gpa, &.{ opts.xdg_config_home, "systemd/user" });
            try dirs.append(gpa, .{ .path = personal, .tier = .personal });
            try dirs.appendSlice(gpa, &user_dirs);
            return dirs.toOwnedSlice(gpa);
        },
    }
}

pub const FileRef = struct {
    /// Path as found in a lookup directory; stable identity of the file.
    path: []const u8,
    /// Path to open: `path` with symlinks resolved inside the filesystem root.
    read_path: []const u8,
    tier: Tier,
    dropin: bool,
};

pub const State = enum { found, masked, not_found };

pub const Resolved = struct {
    /// The requested name.
    name: Name,
    state: State,
    /// The fragment; for a masked unit the masking symlink.
    fragment: ?FileRef = null,
    /// The fragment is the template of an instance.
    template_fallback: bool = false,
    /// Canonical unit name when the fragment is a symlink to a differently named unit file.
    alias_of: ?[]const u8 = null,
    /// Fragment first, then drop-ins in application order.
    files: []const FileRef = &.{},
    /// Existing drop-in directories that were consulted, for change detection.
    dropin_dirs: []const []const u8 = &.{},

    pub fn tier(r: Resolved) ?Tier {
        return if (r.fragment) |f| f.tier else null;
    }

    pub fn instance(r: Resolved) ?[]const u8 {
        return r.name.instance;
    }
};

const Found = union(enum) {
    none,
    masked: FileRef,
    file: struct { ref: FileRef, alias_of: ?[]const u8 },
};

pub fn resolve(gpa: Allocator, fs: Fs, opts: Options, name: Name) !Resolved {
    const dirs = try searchDirs(gpa, opts);
    var template_fallback = false;
    var found = try lookupFragment(gpa, fs, dirs, name.full);
    var template: ?[]const u8 = null;
    if (name.isInstance()) {
        template = try name.templateName(gpa);
        if (found == .none) {
            found = try lookupFragment(gpa, fs, dirs, template.?);
            template_fallback = found != .none;
        }
    }
    switch (found) {
        .none => return .{ .name = name, .state = .not_found },
        .masked => |ref| return .{
            .name = name,
            .state = .masked,
            .fragment = ref,
            .template_fallback = template_fallback,
        },
        .file => |f| {
            var names: std.ArrayList([]const u8) = .empty;
            try names.append(gpa, name.full);
            if (template) |t| try names.append(gpa, t);
            if (f.alias_of) |a| try names.append(gpa, a);
            const drop = try collectDropins(gpa, fs, dirs, name, names.items);
            var files: std.ArrayList(FileRef) = .empty;
            try files.append(gpa, f.ref);
            try files.appendSlice(gpa, drop.files);
            return .{
                .name = name,
                .state = .found,
                .fragment = f.ref,
                .template_fallback = template_fallback,
                .alias_of = f.alias_of,
                .files = try files.toOwnedSlice(gpa),
                .dropin_dirs = drop.dirs,
            };
        },
    }
}

fn joinPath(gpa: Allocator, dir: []const u8, leaf: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, leaf });
}

fn isMissing(err: anyerror) bool {
    return err == error.FileNotFound or err == error.NotDir or err == error.SymLinkLoop;
}

fn isNullTarget(target: []const u8) bool {
    return std.mem.endsWith(u8, target, "/dev/null");
}

const Inspected = union(enum) {
    masked,
    file: struct { read_path: []const u8, alias_of: ?[]const u8 },
    skip,
};

/// Classifies the lookup-directory entry `path` that should hold the unit `expected`. With
/// `empty_masks` an empty file masks like a `/dev/null` symlink; drop-ins may be empty.
fn inspect(gpa: Allocator, fs: Fs, path: []const u8, expected: []const u8, empty_masks: bool) !Inspected {
    const lst = fs.lstat(path) catch |e| {
        if (isMissing(e)) return .skip;
        return e;
    };
    switch (lst.kind) {
        .file => {
            if (empty_masks and lst.size == 0) return .masked;
            return .{ .file = .{ .read_path = path, .alias_of = null } };
        },
        .sym_link => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try fs.readLink(path, &buf);
            if (isNullTarget(target)) return .masked;
            const real = fs.realpath(gpa, path) catch |e| {
                if (isMissing(e)) return .skip;
                return e;
            };
            const st = fs.lstat(real) catch |e| {
                if (isMissing(e)) return .skip;
                return e;
            };
            if (st.kind != .file) return .skip;
            if (empty_masks and st.size == 0) return .masked;
            const base = std.fs.path.basename(target);
            var alias: ?[]const u8 = null;
            if (!std.mem.eql(u8, base, expected)) {
                if (name_mod.parse(gpa, base)) |n| {
                    if (std.mem.eql(u8, n.full, base)) alias = n.full;
                } else |e| switch (e) {
                    error.InvalidName => {},
                    else => return e,
                }
            }
            return .{ .file = .{ .read_path = real, .alias_of = alias } };
        },
        else => return .skip,
    }
}

fn lookupFragment(gpa: Allocator, fs: Fs, dirs: []const SearchDir, unit: []const u8) !Found {
    for (dirs) |d| {
        const path = try joinPath(gpa, d.path, unit);
        switch (try inspect(gpa, fs, path, unit, true)) {
            .skip => continue,
            .masked => return .{ .masked = .{ .path = path, .read_path = path, .tier = d.tier, .dropin = false } },
            .file => |f| return .{ .file = .{
                .ref = .{ .path = path, .read_path = f.read_path, .tier = d.tier, .dropin = false },
                .alias_of = f.alias_of,
            } },
        }
    }
    return .none;
}

const Dropins = struct {
    files: []const FileRef,
    dirs: []const []const u8,
};

const Candidate = struct {
    ref: FileRef,
    null_masked: bool,
};

/// Drop-in directory names, most specific first: per unit name, dashed prefixes, then the type.
fn dropinDirNames(gpa: Allocator, name: Name, names: []const []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (names) |n| try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}.d", .{n}));
    var end = name.prefix.len;
    while (std.mem.findScalarLast(u8, name.prefix[0..end], '-')) |dash| {
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}.{s}.d", .{ name.prefix[0 .. dash + 1], name.kind.suffix() }));
        end = dash;
    }
    try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}.d", .{name.kind.suffix()}));
    return out.toOwnedSlice(gpa);
}

fn collectDropins(
    gpa: Allocator,
    fs: Fs,
    dirs: []const SearchDir,
    name: Name,
    names: []const []const u8,
) !Dropins {
    var chosen: std.StringArrayHashMapUnmanaged(Candidate) = .empty;
    var existing: std.ArrayList([]const u8) = .empty;
    for (try dropinDirNames(gpa, name, names)) |dir_name| {
        for (dirs) |d| {
            const dir_path = try joinPath(gpa, d.path, dir_name);
            const entries = fs.iterateDir(gpa, dir_path) catch |e| {
                if (isMissing(e)) continue;
                return e;
            };
            defer Fs.freeEntries(gpa, entries);
            try existing.append(gpa, dir_path);
            for (entries) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
                const slot = try chosen.getOrPut(gpa, entry.name);
                if (slot.found_existing) continue;
                const path = try joinPath(gpa, dir_path, entry.name);
                const kept = try inspect(gpa, fs, path, entry.name, false);
                switch (kept) {
                    .skip => {
                        _ = chosen.swapRemove(entry.name);
                    },
                    .masked => {
                        slot.key_ptr.* = try gpa.dupe(u8, entry.name);
                        slot.value_ptr.* = .{
                            .ref = .{ .path = path, .read_path = path, .tier = d.tier, .dropin = true },
                            .null_masked = true,
                        };
                    },
                    .file => |f| {
                        slot.key_ptr.* = try gpa.dupe(u8, entry.name);
                        slot.value_ptr.* = .{
                            .ref = .{ .path = path, .read_path = f.read_path, .tier = d.tier, .dropin = true },
                            .null_masked = false,
                        };
                    },
                }
            }
        }
    }
    const keys = chosen.keys();
    const order = try gpa.alloc(usize, keys.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, keys, struct {
        fn lessThan(k: []const []const u8, a: usize, b: usize) bool {
            return std.mem.lessThan(u8, k[a], k[b]);
        }
    }.lessThan);
    var files: std.ArrayList(FileRef) = .empty;
    for (order) |i| {
        const c = chosen.values()[i];
        if (!c.null_masked) try files.append(gpa, c.ref);
    }
    return .{ .files = try files.toOwnedSlice(gpa), .dirs = try existing.toOwnedSlice(gpa) };
}

pub const Listed = struct {
    /// File name in the lookup directory, e.g. `foo.service` or `foo@.service`.
    name: []const u8,
    path: []const u8,
    tier: Tier,
    masked: bool,
    alias_of: ?[]const u8,
};

/// All unit files in the lookup directories, sorted by name; the highest-priority directory
/// wins for a name.
pub fn list(gpa: Allocator, fs: Fs, opts: Options) ![]Listed {
    const dirs = try searchDirs(gpa, opts);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(Listed) = .empty;
    for (dirs) |d| {
        const entries = fs.iterateDir(gpa, d.path) catch |e| {
            if (isMissing(e)) continue;
            return e;
        };
        defer Fs.freeEntries(gpa, entries);
        for (entries) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            const parsed = name_mod.parse(gpa, entry.name) catch |e| switch (e) {
                error.InvalidName => continue,
                else => return e,
            };
            if (!std.mem.eql(u8, parsed.full, entry.name)) continue;
            if (seen.contains(entry.name)) continue;
            const path = try joinPath(gpa, d.path, entry.name);
            const item: Listed = switch (try inspect(gpa, fs, path, entry.name, true)) {
                .skip => continue,
                .masked => .{ .name = parsed.full, .path = path, .tier = d.tier, .masked = true, .alias_of = null },
                .file => |f| .{ .name = parsed.full, .path = path, .tier = d.tier, .masked = false, .alias_of = f.alias_of },
            };
            try seen.put(gpa, parsed.full, {});
            try out.append(gpa, item);
        }
    }
    const items = try out.toOwnedSlice(gpa);
    std.mem.sort(Listed, items, {}, struct {
        fn lessThan(_: void, a: Listed, b: Listed) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return items;
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .tmp = testing.tmpDir(.{ .iterate = true }), .arena = .init(testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn fs(f: *Fixture) Fs {
        return .initDir(testing.io, f.tmp.dir);
    }

    fn a(f: *Fixture) Allocator {
        return f.arena.allocator();
    }

    fn put(f: *Fixture, path: []const u8, content: []const u8) !void {
        const dir = std.fs.path.dirname(path).?;
        try f.fs().makePath(dir);
        try f.fs().writeFileAtomic(path, content, 0o644);
    }

    fn link(f: *Fixture, target: []const u8, path: []const u8) !void {
        try f.fs().makePath(std.fs.path.dirname(path).?);
        try f.fs().symLink(target, path);
    }

    fn resolveName(f: *Fixture, opts: Options, unit: []const u8) !Resolved {
        return resolve(f.a(), f.fs(), opts, try name_mod.parse(f.a(), unit));
    }

    fn read(f: *Fixture, ref: FileRef) ![]u8 {
        return f.fs().readFileAlloc(f.a(), ref.read_path, 1024);
    }
};

const sys: Options = .{ .scope = .system };

fn expectPaths(expected: []const []const u8, files: []const FileRef) !void {
    try testing.expectEqual(expected.len, files.len);
    for (expected, files) |e, f| try testing.expectEqualStrings(e, f.path);
}

test "search directories per scope and tier" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try searchDirs(arena.allocator(), sys);
    try testing.expectEqual(@as(usize, 5), s.len);
    try testing.expectEqualStrings("/etc/systemd/system", s[0].path);
    try testing.expectEqual(Tier.admin, s[0].tier);
    try testing.expectEqualStrings("/run/systemd/system", s[1].path);
    try testing.expectEqual(Tier.runtime, s[1].tier);
    try testing.expectEqualStrings("/usr/local/lib/systemd/system", s[2].path);
    try testing.expectEqual(Tier.vendor, s[3].tier);
    try testing.expectEqualStrings("/lib/systemd/system", s[4].path);
    const u = try searchDirs(arena.allocator(), .{ .scope = .user, .xdg_config_home = "/home/u/.config" });
    try testing.expectEqual(@as(usize, 4), u.len);
    try testing.expectEqualStrings("/home/u/.config/systemd/user", u[0].path);
    try testing.expectEqual(Tier.personal, u[0].tier);
    try testing.expectEqualStrings("/etc/systemd/user", u[1].path);
    try testing.expectEqual(Tier.admin, u[1].tier);
    try testing.expectEqualStrings("/usr/lib/systemd/user", u[3].path);
    try testing.expectEqual(Tier.vendor, u[3].tier);
}

test "not found" {
    var fx: Fixture = .init();
    defer fx.deinit();
    const r = try fx.resolveName(sys, "nothing");
    try testing.expectEqual(State.not_found, r.state);
    try testing.expectEqual(@as(usize, 0), r.files.len);
    try testing.expectEqual(@as(?Tier, null), r.tier());
}

test "first lookup directory wins and carries its tier" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "vendor");
    try fx.put("/lib/systemd/system/foo.service", "lib");
    try fx.put("/etc/systemd/system/foo.service", "admin");
    try fx.put("/usr/lib/systemd/system/bar.service", "vendor-bar");
    try fx.put("/lib/systemd/system/baz.service", "lib-baz");
    try fx.put("/run/systemd/system/rt.service", "rt");
    const foo = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.found, foo.state);
    try testing.expectEqualStrings("/etc/systemd/system/foo.service", foo.fragment.?.path);
    try testing.expectEqual(Tier.admin, foo.tier().?);
    try testing.expectEqualStrings("admin", try fx.read(foo.fragment.?));
    const bar = try fx.resolveName(sys, "bar.service");
    try testing.expectEqual(Tier.vendor, bar.tier().?);
    const baz = try fx.resolveName(sys, "baz");
    try testing.expectEqualStrings("/lib/systemd/system/baz.service", baz.fragment.?.path);
    const rt = try fx.resolveName(sys, "rt");
    try testing.expectEqual(Tier.runtime, rt.tier().?);
}

test "masks: /dev/null symlink in a higher directory masks vendor units" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "vendor");
    try fx.link("/dev/null", "/etc/systemd/system/foo.service");
    try fx.put("/usr/lib/systemd/system/bar.service", "vendor");
    try fx.link("/dev/null", "/run/systemd/system/bar.service");
    const foo = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.masked, foo.state);
    try testing.expectEqual(Tier.admin, foo.tier().?);
    try testing.expectEqual(@as(usize, 0), foo.files.len);
    const bar = try fx.resolveName(sys, "bar");
    try testing.expectEqual(State.masked, bar.state);
    try testing.expectEqual(Tier.runtime, bar.tier().?);
}

test "a vendor mask is overridden by an admin unit" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.link("/dev/null", "/usr/lib/systemd/system/foo.service");
    try fx.put("/etc/systemd/system/foo.service", "admin");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.found, r.state);
    try testing.expectEqual(Tier.admin, r.tier().?);
}

test "an empty fragment masks like /dev/null" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "vendor");
    try fx.put("/etc/systemd/system/foo.service", "");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.masked, r.state);
    try testing.expectEqual(Tier.admin, r.tier().?);
    try testing.expectEqual(@as(usize, 0), r.files.len);
}

test "an empty vendor fragment is overridden by an admin unit" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "");
    try fx.put("/etc/systemd/system/foo.service", "admin");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.found, r.state);
    try testing.expectEqual(Tier.admin, r.tier().?);
}

test "a symlink to an empty file masks" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "vendor");
    try fx.put("/srv/empty", "");
    try fx.link("/srv/empty", "/etc/systemd/system/foo.service");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.masked, r.state);
}

test "an empty template fragment masks its instances" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/etc/systemd/system/foo@.service", "");
    const r = try fx.resolveName(sys, "foo@bar");
    try testing.expectEqual(State.masked, r.state);
    try testing.expect(r.template_fallback);
}

test "an empty drop-in is kept" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "frag");
    try fx.put("/etc/systemd/system/foo.service.d/10-empty.conf", "");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(@as(usize, 2), r.files.len);
}

test "list reports empty files as masked" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/etc/systemd/system/e.service", "");
    const items = try list(fx.a(), fx.fs(), sys);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expect(items[0].masked);
}

test "masks via relative and nested /dev/null targets" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.link("../../../dev/null", "/etc/systemd/system/foo.service");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.masked, r.state);
}

test "alias symlink to another unit name" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/gdm.service", "gdm body");
    try fx.link("/usr/lib/systemd/system/gdm.service", "/etc/systemd/system/display-manager.service");
    const r = try fx.resolveName(sys, "display-manager");
    try testing.expectEqual(State.found, r.state);
    try testing.expectEqualStrings("gdm.service", r.alias_of.?);
    try testing.expectEqualStrings("/etc/systemd/system/display-manager.service", r.fragment.?.path);
    try testing.expectEqualStrings("/usr/lib/systemd/system/gdm.service", r.fragment.?.read_path);
    try testing.expectEqualStrings("gdm body", try fx.read(r.fragment.?));
}

test "relative alias symlink in the same directory" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/etc/systemd/system/real.service", "real");
    try fx.link("real.service", "/etc/systemd/system/other.service");
    const r = try fx.resolveName(sys, "other.service");
    try testing.expectEqualStrings("real.service", r.alias_of.?);
    try testing.expectEqualStrings("real", try fx.read(r.fragment.?));
}

test "symlink to a same-named file is not an alias" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "vendor");
    try fx.link("/usr/lib/systemd/system/foo.service", "/etc/systemd/system/foo.service");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(@as(?[]const u8, null), r.alias_of);
    try testing.expectEqual(Tier.admin, r.tier().?);
    try testing.expectEqualStrings("vendor", try fx.read(r.fragment.?));
}

test "dangling symlink is skipped and lookup continues" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.link("/nonexistent/x.service", "/etc/systemd/system/foo.service");
    try fx.put("/usr/lib/systemd/system/foo.service", "vendor");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.found, r.state);
    try testing.expectEqual(Tier.vendor, r.tier().?);
}

test "template fallback and exact instance precedence" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo@.service", "template");
    const r = try fx.resolveName(sys, "foo@bar.service");
    try testing.expectEqual(State.found, r.state);
    try testing.expect(r.template_fallback);
    try testing.expectEqualStrings("bar", r.instance().?);
    try testing.expectEqualStrings("/usr/lib/systemd/system/foo@.service", r.fragment.?.path);
    try fx.put("/etc/systemd/system/foo@bar.service", "exact");
    const exact = try fx.resolveName(sys, "foo@bar");
    try testing.expect(!exact.template_fallback);
    try testing.expectEqualStrings("exact", try fx.read(exact.fragment.?));
    const other = try fx.resolveName(sys, "foo@baz");
    try testing.expect(other.template_fallback);
    const tmpl = try fx.resolveName(sys, "foo@.service");
    try testing.expectEqual(State.found, tmpl.state);
    try testing.expect(!tmpl.template_fallback);
}

test "an instance without a template is not found" {
    var fx: Fixture = .init();
    defer fx.deinit();
    const r = try fx.resolveName(sys, "foo@bar");
    try testing.expectEqual(State.not_found, r.state);
}

test "drop-ins are ordered by file name across directories" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "frag");
    try fx.put("/usr/lib/systemd/system/foo.service.d/20-vendor.conf", "v20");
    try fx.put("/etc/systemd/system/foo.service.d/10-admin.conf", "a10");
    try fx.put("/run/systemd/system/foo.service.d/15-run.conf", "r15");
    try fx.put("/etc/systemd/system/foo.service.d/30-admin.conf", "a30");
    try fx.put("/etc/systemd/system/foo.service.d/readme.txt", "ignored");
    const r = try fx.resolveName(sys, "foo");
    try expectPaths(&.{
        "/usr/lib/systemd/system/foo.service",
        "/etc/systemd/system/foo.service.d/10-admin.conf",
        "/run/systemd/system/foo.service.d/15-run.conf",
        "/usr/lib/systemd/system/foo.service.d/20-vendor.conf",
        "/etc/systemd/system/foo.service.d/30-admin.conf",
    }, r.files);
    try testing.expect(!r.files[0].dropin);
    try testing.expect(r.files[1].dropin);
    try testing.expectEqual(Tier.runtime, r.files[2].tier);
    try testing.expectEqual(Tier.vendor, r.files[3].tier);
}

test "same-named drop-in: highest-priority directory wins" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "frag");
    try fx.put("/usr/lib/systemd/system/foo.service.d/10-x.conf", "vendor");
    try fx.put("/etc/systemd/system/foo.service.d/10-x.conf", "admin");
    try fx.put("/lib/systemd/system/foo.service.d/10-x.conf", "lib");
    const r = try fx.resolveName(sys, "foo");
    try expectPaths(&.{
        "/usr/lib/systemd/system/foo.service",
        "/etc/systemd/system/foo.service.d/10-x.conf",
    }, r.files);
    try testing.expectEqualStrings("admin", try fx.read(r.files[1]));
}

test "a drop-in symlinked to /dev/null disables lower-priority drop-ins of that name" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "frag");
    try fx.put("/usr/lib/systemd/system/foo.service.d/10-x.conf", "vendor");
    try fx.put("/usr/lib/systemd/system/foo.service.d/20-y.conf", "vendor-y");
    try fx.link("/dev/null", "/etc/systemd/system/foo.service.d/10-x.conf");
    const r = try fx.resolveName(sys, "foo");
    try expectPaths(&.{
        "/usr/lib/systemd/system/foo.service",
        "/usr/lib/systemd/system/foo.service.d/20-y.conf",
    }, r.files);
}

test "type and prefix drop-ins apply to dashed names" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo-bar-baz.service", "frag");
    try fx.put("/etc/systemd/system/service.d/00-type.conf", "t");
    try fx.put("/etc/systemd/system/foo-.service.d/10-foo.conf", "p1");
    try fx.put("/etc/systemd/system/foo-bar-.service.d/20-foobar.conf", "p2");
    try fx.put("/etc/systemd/system/foo-bar-baz.service.d/30-own.conf", "own");
    try fx.put("/etc/systemd/system/other-.service.d/99-other.conf", "no");
    try fx.put("/etc/systemd/system/timer.d/99-timer.conf", "no");
    const r = try fx.resolveName(sys, "foo-bar-baz");
    try expectPaths(&.{
        "/usr/lib/systemd/system/foo-bar-baz.service",
        "/etc/systemd/system/service.d/00-type.conf",
        "/etc/systemd/system/foo-.service.d/10-foo.conf",
        "/etc/systemd/system/foo-bar-.service.d/20-foobar.conf",
        "/etc/systemd/system/foo-bar-baz.service.d/30-own.conf",
    }, r.files);
}

test "a more specific drop-in directory wins over a less specific one for the same file name" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "frag");
    try fx.put("/usr/lib/systemd/system/foo.service.d/10-x.conf", "specific");
    try fx.put("/etc/systemd/system/service.d/10-x.conf", "type");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(@as(usize, 2), r.files.len);
    try testing.expectEqualStrings("specific", try fx.read(r.files[1]));
}

test "instances get template, instance and prefix drop-ins" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/my-app@.service", "tmpl");
    try fx.put("/etc/systemd/system/my-app@.service.d/10-template.conf", "t");
    try fx.put("/etc/systemd/system/my-app@one.service.d/20-instance.conf", "i");
    try fx.put("/etc/systemd/system/my-app@two.service.d/20-instance.conf", "other");
    try fx.put("/etc/systemd/system/my-.service.d/05-prefix.conf", "p");
    const r = try fx.resolveName(sys, "my-app@one");
    try expectPaths(&.{
        "/usr/lib/systemd/system/my-app@.service",
        "/etc/systemd/system/my-.service.d/05-prefix.conf",
        "/etc/systemd/system/my-app@.service.d/10-template.conf",
        "/etc/systemd/system/my-app@one.service.d/20-instance.conf",
    }, r.files);
}

test "alias drop-ins come from the canonical name too" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/etc/systemd/system/real.service", "real");
    try fx.link("real.service", "/etc/systemd/system/alias.service");
    try fx.put("/etc/systemd/system/real.service.d/10-real.conf", "r");
    try fx.put("/etc/systemd/system/alias.service.d/20-alias.conf", "a");
    const r = try fx.resolveName(sys, "alias");
    try testing.expectEqual(@as(usize, 3), r.files.len);
}

test "unit with only drop-ins is not found" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/etc/systemd/system/foo.service.d/10.conf", "x");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(State.not_found, r.state);
}

test "existing drop-in directories are reported" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/foo.service", "frag");
    try fx.put("/etc/systemd/system/foo.service.d/10.conf", "x");
    try fx.put("/usr/lib/systemd/system/service.d/00.conf", "y");
    const r = try fx.resolveName(sys, "foo");
    try testing.expectEqual(@as(usize, 2), r.dropin_dirs.len);
    try testing.expectEqualStrings("/etc/systemd/system/foo.service.d", r.dropin_dirs[0]);
    try testing.expectEqualStrings("/usr/lib/systemd/system/service.d", r.dropin_dirs[1]);
}

test "user scope: personal, admin and vendor user directories" {
    var fx: Fixture = .init();
    defer fx.deinit();
    const opts: Options = .{ .scope = .user, .xdg_config_home = "/home/u/.config" };
    try fx.put("/usr/lib/systemd/user/a.service", "vendor");
    try fx.put("/etc/systemd/user/a.service", "admin");
    try fx.put("/home/u/.config/systemd/user/b.service", "personal");
    try fx.put("/usr/local/lib/systemd/user/c.service", "local");
    try fx.put("/etc/systemd/system/sysonly.service", "sys");
    try fx.put("/home/u/.config/systemd/user/a.service.d/10.conf", "d");
    const a = try fx.resolveName(opts, "a");
    try testing.expectEqual(Tier.admin, a.tier().?);
    try testing.expectEqual(@as(usize, 2), a.files.len);
    try testing.expectEqual(Tier.personal, a.files[1].tier);
    const b = try fx.resolveName(opts, "b");
    try testing.expectEqual(Tier.personal, b.tier().?);
    try testing.expectEqualStrings("/home/u/.config/systemd/user/b.service", b.fragment.?.path);
    const c = try fx.resolveName(opts, "c");
    try testing.expectEqual(Tier.vendor, c.tier().?);
    const s = try fx.resolveName(opts, "sysonly");
    try testing.expectEqual(State.not_found, s.state);
    const sys_a = try fx.resolveName(sys, "a");
    try testing.expectEqual(State.not_found, sys_a.state);
}

test "list merges directories, masks and aliases" {
    var fx: Fixture = .init();
    defer fx.deinit();
    try fx.put("/usr/lib/systemd/system/b.service", "v");
    try fx.put("/etc/systemd/system/b.service", "a");
    try fx.put("/usr/lib/systemd/system/a.timer", "t");
    try fx.put("/usr/lib/systemd/system/t@.service", "tmpl");
    try fx.link("/dev/null", "/etc/systemd/system/m.service");
    try fx.link("b.service", "/etc/systemd/system/al.service");
    try fx.put("/etc/systemd/system/notaunit.txt", "x");
    try fx.put("/etc/systemd/system/nosuffix", "x");
    try fx.put("/etc/systemd/system/b.service.d/10.conf", "x");
    const items = try list(fx.a(), fx.fs(), sys);
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("a.timer", items[0].name);
    try testing.expectEqualStrings("al.service", items[1].name);
    try testing.expectEqualStrings("b.service", items[2].name);
    try testing.expectEqualStrings("m.service", items[3].name);
    try testing.expect(items[3].masked);
    try testing.expectEqualStrings("t@.service", items[4].name);
    try testing.expectEqual(Tier.admin, items[2].tier);
    try testing.expectEqualStrings("b.service", items[1].alias_of.?);
}
