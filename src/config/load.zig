// SPDX-License-Identifier: GPL-3.0-or-later
//! Configuration loading (§5): defaults, `/etc/fake-systemd/fake-systemd.conf`, its `.conf.d`
//! drop-ins in lexical order, the user file in user scope, then environment overrides.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("Config.zig");
const Diag = @import("../core/Diag.zig");
const Fs = @import("../core/Fs.zig");
const Scope = @import("../core/types.zig").Scope;
const ini = @import("../unit/ini.zig");
const name_mod = @import("../unit/name.zig");
const execline = @import("../unit/execline.zig");
const model = @import("../unit/model.zig");

pub const default_etc_dir = "/etc/fake-systemd";
pub const conf_name = "fake-systemd.conf";
const max_file_size = 1 << 20;

pub const Options = struct {
    scope: Scope,
    /// Directory holding the user file `fake-systemd/fake-systemd.conf`; user scope only.
    xdg_config_home: []const u8 = "/root/.config",
    etc_dir: []const u8 = default_etc_dir,
    /// Source of the `FAKE_SYSTEMD_*` overrides; none are applied when null.
    environ: ?*const std.process.Environ.Map = null,
};

/// Loads the effective configuration. Problems in files or the environment are reported as
/// warnings on `diag` and the offending setting is skipped.
pub fn load(gpa: Allocator, fs: Fs, diag: *Diag, opts: Options) Allocator.Error!Config {
    var loader: Loader = .{ .gpa = gpa, .diag = diag };

    const main_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.etc_dir, conf_name });
    try loader.loadFile(fs, main_path);
    try loader.loadDropins(fs, try std.fmt.allocPrint(gpa, "{s}/{s}.d", .{ opts.etc_dir, conf_name }));
    if (opts.scope == .user) {
        try loader.loadFile(fs, try std.fmt.allocPrint(gpa, "{s}/fake-systemd/{s}", .{ opts.xdg_config_home, conf_name }));
    }
    if (opts.environ) |env| try loader.applyEnvironment(env);
    return loader.finish();
}

const Loader = struct {
    gpa: Allocator,
    diag: *Diag,
    config: Config = .{},
    allow: std.ArrayList([]const u8) = .empty,
    deny: std.ArrayList([]const u8) = .empty,
    load_error: ?[]const u8 = null,

    fn finish(l: *Loader) Allocator.Error!Config {
        var c = l.config;
        c.allow = try l.allow.toOwnedSlice(l.gpa);
        c.deny = try l.deny.toOwnedSlice(l.gpa);
        c.load_error = l.load_error;
        return c;
    }

    fn fatal(l: *Loader, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const text = try std.fmt.allocPrint(l.gpa, fmt, args);
        l.diag.warn("{s}", .{text});
        if (l.load_error == null) l.load_error = text;
    }

    fn loadDropins(l: *Loader, fs: Fs, dir: []const u8) Allocator.Error!void {
        const entries = fs.iterateDir(l.gpa, dir) catch |e| {
            if (e == error.FileNotFound or e == error.NotDir) return;
            try l.fatal("cannot read {s}: {t}", .{ dir, e });
            return;
        };
        defer Fs.freeEntries(l.gpa, entries);
        for (entries) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            try l.loadFile(fs, try std.fmt.allocPrint(l.gpa, "{s}/{s}", .{ dir, entry.name }));
        }
    }

    fn loadFile(l: *Loader, fs: Fs, path: []const u8) Allocator.Error!void {
        const content = fs.readFileAlloc(l.gpa, path, max_file_size) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotDir => return,
            else => return l.fatal("cannot read {s}: {t}", .{ path, e }),
        };
        var doc: ini.Document = .empty;
        try ini.parse(l.gpa, &doc, content, 0);
        for (doc.problems.items) |p| {
            try l.fatal("{s}:{d}: syntax error ({t})", .{ path, p.line, p.kind });
        }
        for (doc.sections.items, 0..) |s, i| {
            if (isKnownSection(s.name) or sectionSeenBefore(doc, i)) continue;
            l.diag.warn("{s}:{d}: unknown section [{s}]", .{ path, s.line, s.name });
        }
        for (doc.entries.items) |e| try l.apply(path, e);
    }

    fn apply(l: *Loader, path: []const u8, e: ini.Entry) Allocator.Error!void {
        if (eql(e.section, "Main")) {
            if (eql(e.key, "Init")) {
                l.config.init = orDefault(e.value, "auto");
            } else if (eql(e.key, "Profile")) {
                l.config.profile = orDefault(e.value, "auto");
            } else if (eql(e.key, "Translate")) {
                l.config.translate = try l.choice(Config.Translate, path, e, l.config.translate, .lazy);
            } else try l.unknownKey(path, e);
        } else if (eql(e.section, "Timers")) {
            if (eql(e.key, "Scheduler")) {
                l.config.timers_scheduler = try l.choice(Config.TimersScheduler, path, e, l.config.timers_scheduler, .auto);
            } else try l.unknownKey(path, e);
        } else if (eql(e.section, "Aliases")) {
            try l.applyAlias(path, e);
        } else if (eql(e.section, "Classify")) {
            if (eql(e.key, "Allow")) {
                try l.applyGlobs(path, e, &l.allow);
            } else if (eql(e.key, "Deny")) {
                try l.applyGlobs(path, e, &l.deny);
            } else try l.unknownKey(path, e);
        }
    }

    fn choice(l: *Loader, comptime T: type, path: []const u8, e: ini.Entry, current: T, default: T) Allocator.Error!T {
        if (e.value.len == 0) return default;
        return std.meta.stringToEnum(T, e.value) orelse {
            l.diag.warn("{s}:{d}: invalid value '{s}' for {s}=", .{ path, e.line, e.value, e.key });
            return current;
        };
    }

    fn unknownKey(l: *Loader, path: []const u8, e: ini.Entry) Allocator.Error!void {
        l.diag.warn("{s}:{d}: unknown key '{s}' in section [{s}]", .{ path, e.line, e.key, e.section });
    }

    fn applyAlias(l: *Loader, path: []const u8, e: ini.Entry) Allocator.Error!void {
        const unit = name_mod.parse(l.gpa, e.key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidName => {
                l.diag.warn("{s}:{d}: invalid unit name '{s}' in section [Aliases]", .{ path, e.line, e.key });
                return;
            },
        };
        if (e.value.len == 0) {
            _ = l.config.aliases.remove(unit.full);
            return;
        }
        try l.config.aliases.put(l.gpa, unit.full, e.value);
    }

    fn applyGlobs(l: *Loader, path: []const u8, e: ini.Entry, list: *std.ArrayList([]const u8)) Allocator.Error!void {
        if (e.value.len == 0) {
            list.clearRetainingCapacity();
            return;
        }
        const words = execline.splitWords(l.gpa, e.value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (std.mem.eql(u8, e.key, "Deny")) return l.fatal("{s}:{d}: invalid value for Deny= ({t})", .{ path, e.line, err });
                l.diag.warn("{s}:{d}: invalid value for {s}= ({t})", .{ path, e.line, e.key, err });
                return;
            },
        };
        try list.appendSlice(l.gpa, words);
    }

    fn applyEnvironment(l: *Loader, env: *const std.process.Environ.Map) Allocator.Error!void {
        if (nonEmpty(env.get("FAKE_SYSTEMD_INIT"))) |v| l.config.init = v;
        if (nonEmpty(env.get("FAKE_SYSTEMD_PROFILE"))) |v| l.config.profile = v;
        if (nonEmpty(env.get("FAKE_SYSTEMD_DRY_RUN"))) |v| {
            if (model.parseBool(v)) |b| {
                l.config.dry_run = b;
            } else {
                l.diag.warn("invalid value '{s}' for FAKE_SYSTEMD_DRY_RUN", .{v});
            }
        }
        if (nonEmpty(env.get("FAKE_SYSTEMD_LOG_LEVEL"))) |v| {
            if (parseLevel(v)) |lv| {
                l.config.log_level = lv;
            } else {
                l.diag.warn("invalid value '{s}' for FAKE_SYSTEMD_LOG_LEVEL", .{v});
            }
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn orDefault(value: []const u8, default: []const u8) []const u8 {
    return if (value.len == 0) default else value;
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

fn isKnownSection(name: []const u8) bool {
    const known = [_][]const u8{ "Main", "Timers", "Aliases", "Classify" };
    for (known) |k| if (eql(k, name)) return true;
    return false;
}

fn sectionSeenBefore(doc: ini.Document, index: usize) bool {
    const name = doc.sections.items[index].name;
    for (doc.sections.items[0..index]) |s| if (eql(s.name, name)) return true;
    return false;
}

pub fn parseLevel(s: []const u8) ?Diag.Level {
    const names = [_]struct { []const u8, Diag.Level }{
        .{ "error", .@"error" },
        .{ "warning", .warning },
        .{ "warn", .warning },
        .{ "notice", .notice },
        .{ "info", .info },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n[0])) return n[1];
    return null;
}

const testing = std.testing;
const Io = std.Io;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    out: [4096]u8 = undefined,
    writer: Io.Writer = undefined,
    diag: Diag = undefined,

    fn init(f: *Fixture) void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.arena = .init(testing.allocator);
        f.writer = .fixed(&f.out);
        f.diag = .init(&f.writer, .info);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn fs(f: *Fixture) Fs {
        return .initDir(testing.io, f.tmp.dir);
    }

    fn put(f: *Fixture, path: []const u8, content: []const u8) !void {
        try f.fs().makePath(std.fs.path.dirname(path).?);
        try f.fs().writeFileAtomic(path, content, 0o644);
    }

    fn run(f: *Fixture, opts: Options) !Config {
        return load(f.arena.allocator(), f.fs(), &f.diag, opts);
    }

    fn warnings(f: *Fixture) []const u8 {
        return f.writer.buffered();
    }
};

fn system_opts() Options {
    return .{ .scope = .system };
}

test "no files yields defaults without diagnostics" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const c = try f.run(system_opts());
    try testing.expectEqualStrings("auto", c.init);
    try testing.expectEqualStrings("auto", c.profile);
    try testing.expectEqual(Config.Translate.lazy, c.translate);
    try testing.expectEqual(Config.TimersScheduler.auto, c.timers_scheduler);
    try testing.expectEqual(@as(usize, 0), c.allow.len);
    try testing.expectEqualStrings("", f.warnings());
}

test "main file sets every section" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf",
        \\# comment
        \\[Main]
        \\Init=dinit
        \\Profile=artix
        \\Translate=eager
        \\
        \\[Timers]
        \\Scheduler=builtin
        \\
        \\[Aliases]
        \\foo.service=bar
        \\baz=qux
        \\
        \\[Classify]
        \\Allow=systemd-resolved foo-*
        \\Deny=bad "quoted glob"
        \\
    );
    const c = try f.run(system_opts());
    try testing.expectEqualStrings("dinit", c.init);
    try testing.expectEqualStrings("artix", c.profile);
    try testing.expectEqual(Config.Translate.eager, c.translate);
    try testing.expectEqual(Config.TimersScheduler.builtin, c.timers_scheduler);
    try testing.expectEqualStrings("bar", c.aliases.get("foo.service").?);
    try testing.expectEqualStrings("qux", c.aliases.get("baz.service").?);
    try testing.expectEqual(@as(usize, 2), c.allow.len);
    try testing.expectEqualStrings("foo-*", c.allow[1]);
    try testing.expectEqual(@as(usize, 2), c.deny.len);
    try testing.expectEqualStrings("quoted glob", c.deny[1]);
    try testing.expectEqualStrings("", f.warnings());
}

test "drop-ins apply in lexical order after the main file" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Main]\nInit=main\nProfile=main\n[Classify]\nAllow=a\n");
    try f.put("/etc/fake-systemd/fake-systemd.conf.d/20-b.conf", "[Main]\nInit=second\n[Classify]\nAllow=c\n");
    try f.put("/etc/fake-systemd/fake-systemd.conf.d/10-a.conf", "[Main]\nInit=first\nProfile=dropin\n[Classify]\nAllow=b\n");
    try f.put("/etc/fake-systemd/fake-systemd.conf.d/99.txt", "[Main]\nInit=ignored\n");
    const c = try f.run(system_opts());
    try testing.expectEqualStrings("second", c.init);
    try testing.expectEqualStrings("dropin", c.profile);
    try testing.expectEqual(@as(usize, 3), c.allow.len);
    try testing.expectEqualStrings("a", c.allow[0]);
    try testing.expectEqualStrings("b", c.allow[1]);
    try testing.expectEqualStrings("c", c.allow[2]);
}

test "empty assignment resets values and lists" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Main]\nInit=dinit\nTranslate=eager\n[Classify]\nAllow=a b\nDeny=x\n[Aliases]\nfoo=bar\n");
    try f.put("/etc/fake-systemd/fake-systemd.conf.d/10.conf", "[Main]\nInit=\nTranslate=\n[Classify]\nAllow=\nAllow=c\nDeny=\n[Aliases]\nfoo=\n");
    const c = try f.run(system_opts());
    try testing.expectEqualStrings("auto", c.init);
    try testing.expectEqual(Config.Translate.lazy, c.translate);
    try testing.expectEqual(@as(usize, 1), c.allow.len);
    try testing.expectEqual(@as(usize, 0), c.deny.len);
    try testing.expectEqual(@as(usize, 0), c.aliases.count());
}

test "user file applies only in user scope and after system files" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Main]\nInit=system\nProfile=system\n");
    try f.put("/home/u/.config/fake-systemd/fake-systemd.conf", "[Main]\nInit=user\n");
    const sys = try f.run(.{ .scope = .system, .xdg_config_home = "/home/u/.config" });
    try testing.expectEqualStrings("system", sys.init);
    const usr = try f.run(.{ .scope = .user, .xdg_config_home = "/home/u/.config" });
    try testing.expectEqualStrings("user", usr.init);
    try testing.expectEqualStrings("system", usr.profile);
}

test "environment overrides files" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Main]\nInit=file\nProfile=file\n");
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("FAKE_SYSTEMD_INIT", "openrc");
    try env.put("FAKE_SYSTEMD_PROFILE", "alpine");
    try env.put("FAKE_SYSTEMD_DRY_RUN", "1");
    try env.put("FAKE_SYSTEMD_LOG_LEVEL", "INFO");
    const c = try f.run(.{ .scope = .system, .environ = &env });
    try testing.expectEqualStrings("openrc", c.init);
    try testing.expectEqualStrings("alpine", c.profile);
    try testing.expect(c.dry_run);
    try testing.expectEqual(@as(?Diag.Level, .info), c.log_level);
    try testing.expectEqualStrings("", f.warnings());
}

test "empty environment variables are ignored, invalid ones warn" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("FAKE_SYSTEMD_INIT", "");
    try env.put("FAKE_SYSTEMD_DRY_RUN", "perhaps");
    try env.put("FAKE_SYSTEMD_LOG_LEVEL", "loud");
    const c = try f.run(.{ .scope = .system, .environ = &env });
    try testing.expectEqualStrings("auto", c.init);
    try testing.expect(!c.dry_run);
    try testing.expectEqual(@as(?Diag.Level, null), c.log_level);
    try testing.expect(std.mem.indexOf(u8, f.warnings(), "FAKE_SYSTEMD_DRY_RUN") != null);
    try testing.expect(std.mem.indexOf(u8, f.warnings(), "FAKE_SYSTEMD_LOG_LEVEL") != null);
}

test "boolean spellings for dry run" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    for ([_]struct { []const u8, bool }{ .{ "yes", true }, .{ "true", true }, .{ "0", false }, .{ "off", false } }) |case| {
        try env.put("FAKE_SYSTEMD_DRY_RUN", case[0]);
        const c = try f.run(.{ .scope = .system, .environ = &env });
        try testing.expectEqual(case[1], c.dry_run);
    }
}

test "unknown keys and sections produce warnings with file and line" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf",
        \\[Main]
        \\Init=dinit
        \\Colour=blue
        \\[Timers]
        \\Speed=fast
        \\[Classify]
        \\Maybe=1
        \\[Bogus]
        \\A=1
        \\[Bogus]
        \\B=2
        \\
    );
    const c = try f.run(system_opts());
    try testing.expectEqualStrings("dinit", c.init);
    const w = f.warnings();
    try testing.expect(std.mem.indexOf(u8, w, "fake-systemd: warning: /etc/fake-systemd/fake-systemd.conf:3: unknown key 'Colour' in section [Main]") != null);
    try testing.expect(std.mem.indexOf(u8, w, ":5: unknown key 'Speed' in section [Timers]") != null);
    try testing.expect(std.mem.indexOf(u8, w, ":7: unknown key 'Maybe' in section [Classify]") != null);
    try testing.expect(std.mem.indexOf(u8, w, ":8: unknown section [Bogus]") != null);
    try testing.expect(std.mem.indexOf(u8, w, ":10: unknown section [Bogus]") == null);
}

test "invalid values warn and keep the previous value" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Main]\nTranslate=eager\n[Timers]\nScheduler=native\n");
    try f.put("/etc/fake-systemd/fake-systemd.conf.d/10.conf", "[Main]\nTranslate=sometimes\n[Timers]\nScheduler=quartz\n[Aliases]\n=x\nbad/name=y\n[Classify]\nAllow=\"open\n");
    const c = try f.run(system_opts());
    try testing.expectEqual(Config.Translate.eager, c.translate);
    try testing.expectEqual(Config.TimersScheduler.native, c.timers_scheduler);
    const w = f.warnings();
    try testing.expect(std.mem.indexOf(u8, w, "invalid value 'sometimes' for Translate=") != null);
    try testing.expect(std.mem.indexOf(u8, w, "invalid value 'quartz' for Scheduler=") != null);
    try testing.expect(std.mem.indexOf(u8, w, "invalid unit name 'bad/name'") != null);
    try testing.expect(std.mem.indexOf(u8, w, "syntax error (empty_key)") != null);
    try testing.expect(std.mem.indexOf(u8, w, "invalid value for Allow=") != null);
    try testing.expectEqual(@as(usize, 0), c.aliases.count());
}

test "syntax errors warn" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "Init=x\n[Main]\nnonsense\nInit=ok\n");
    const c = try f.run(system_opts());
    try testing.expectEqualStrings("ok", c.init);
    try testing.expect(std.mem.indexOf(u8, f.warnings(), ":1: syntax error (assignment_outside_section)") != null);
    try testing.expect(std.mem.indexOf(u8, f.warnings(), ":3: syntax error (missing_equals)") != null);
}

test "line continuation works in configuration values" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Classify]\nAllow=a \\\n  b \\\n  c\n");
    const c = try f.run(system_opts());
    try testing.expectEqual(@as(usize, 3), c.allow.len);
}

test "custom etc directory" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/alt/fake-systemd.conf", "[Main]\nInit=alt\n");
    try f.put("/alt/fake-systemd.conf.d/x.conf", "[Main]\nProfile=altp\n");
    const c = try f.run(.{ .scope = .system, .etc_dir = "/alt" });
    try testing.expectEqualStrings("alt", c.init);
    try testing.expectEqualStrings("altp", c.profile);
}

test "level names" {
    try testing.expectEqual(@as(?Diag.Level, .@"error"), parseLevel("error"));
    try testing.expectEqual(@as(?Diag.Level, .warning), parseLevel("warn"));
    try testing.expectEqual(@as(?Diag.Level, .notice), parseLevel("Notice"));
    try testing.expectEqual(@as(?Diag.Level, null), parseLevel("debug"));
}

test "a malformed Deny= or a syntax error makes the configuration unusable" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Classify]\nDeny=\"open\n");
    const c = try f.run(system_opts());
    try testing.expect(c.load_error != null);
    try testing.expect(std.mem.indexOf(u8, c.load_error.?, "Deny=") != null);
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Classify]\nDeny foo\n");
    const d = try f.run(system_opts());
    try testing.expect(d.load_error != null);
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Classify]\nDeny=foo\n");
    const ok = try f.run(system_opts());
    try testing.expect(ok.load_error == null);
}

test "an oversized or unreadable file makes the configuration unusable" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const big = try testing.allocator.alloc(u8, max_file_size + 16);
    defer testing.allocator.free(big);
    @memset(big, '#');
    try f.put("/etc/fake-systemd/fake-systemd.conf", big);
    const c = try f.run(system_opts());
    try testing.expect(c.load_error != null);
    try testing.expect(std.mem.indexOf(u8, c.load_error.?, "fake-systemd.conf") != null);
    try f.put("/etc/fake-systemd/fake-systemd.conf", "[Main]\nInit=x\n");
    try f.put("/etc/fake-systemd/fake-systemd.conf.d/10.conf", big);
    const d = try f.run(system_opts());
    try testing.expect(d.load_error != null);
}
