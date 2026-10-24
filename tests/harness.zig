//! Test harness: a tmp root, the fake backend and a recording runner behind the real `ops` entry point.
const std = @import("std");
const Io = std.Io;
const fs_sys = @import("fake_systemd");

pub const core = fs_sys.core;
pub const ops = fs_sys.ops;
pub const backend = fs_sys.backend;
pub const index = fs_sys.index;
pub const detect = fs_sys.detect;
pub const unit = fs_sys.unit;

const testing = std.testing;

pub const Harness = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    fs: core.Fs,
    environ: std.process.Environ.Map,
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,
    diag: core.Diag,
    ctx: core.Context,
    fake: backend.Fake,
    rec: backend.runner.Recording,
    backend_override: ?backend.Backend = null,
    detected: []const u8 = "fake",

    pub fn init(h: *Harness) !void {
        h.arena = .init(testing.allocator);
        const alloc = h.arena.allocator();
        h.tmp = testing.tmpDir(.{ .iterate = true });
        h.fs = .initDir(testing.io, h.tmp.dir);
        h.environ = .init(alloc);
        try h.environ.put("HOME", "/root");
        h.out = .init(alloc);
        h.err = .init(alloc);
        h.diag = .init(&h.err.writer, .notice);
        h.ctx = try .init(alloc, testing.io, &h.fs, &h.diag, &h.environ, .system, 0);
        h.fake = .init(alloc);
        h.rec = .{ .gpa = alloc };
        h.backend_override = null;
        h.detected = "fake";
    }

    pub fn deinit(h: *Harness) void {
        h.tmp.cleanup();
        h.arena.deinit();
    }

    pub fn a(h: *Harness) std.mem.Allocator {
        return h.arena.allocator();
    }

    pub fn write(h: *Harness, path: []const u8, content: []const u8, mode: u16) !void {
        try h.fs.makePath(std.fs.path.dirname(path).?);
        try h.fs.writeFileAtomic(path, content, mode);
    }

    pub fn read(h: *Harness, path: []const u8) ![]u8 {
        return h.fs.readFileAlloc(h.a(), path, 1 << 20);
    }

    pub fn exists(h: *Harness, path: []const u8) bool {
        return h.fs.exists(path);
    }

    /// Writes a service unit and its executable.
    pub fn addUnit(h: *Harness, dir: []const u8, name: []const u8, exec: []const u8, install: ?[]const u8) !void {
        const path = try std.fmt.allocPrint(h.a(), "{s}/{s}", .{ dir, name });
        const text = try std.fmt.allocPrint(
            h.a(),
            "[Unit]\nDescription=Unit {s}\n\n[Service]\nExecStart={s} --run\n{s}",
            .{ name, exec, if (install) |i| try std.fmt.allocPrint(h.a(), "\n[Install]\n{s}\n", .{i}) else "" },
        );
        try h.write(path, text, 0o644);
        if (!h.exists(exec)) try h.write(exec, "#!/bin/sh\n", 0o755);
    }

    /// Writes a native service file that runs `exec`.
    pub fn addNative(h: *Harness, name: []const u8, exec: []const u8) !void {
        const path = try std.fmt.allocPrint(h.a(), "/etc/fake-native/{s}", .{name});
        try h.write(path, try std.fmt.allocPrint(h.a(), "exec = {s}\n", .{exec}), 0o644);
    }

    pub fn addFoo(h: *Harness) !void {
        try h.addUnit("/usr/lib/systemd/system", "foo.service", "/usr/bin/foo", "WantedBy=multi-user.target");
    }

    pub fn deps(h: *Harness) ops.Deps {
        return .{
            .backend = h.backend_override orelse h.fake.backend(),
            .runner = h.rec.runner(),
            .out = &h.out.writer,
            .err = &h.err.writer,
            .detected = h.detected,
        };
    }

    /// Runs `systemctl` with `args`; output buffers are cleared first.
    pub fn run(h: *Harness, args: []const []const u8) u8 {
        h.out.clearRetainingCapacity();
        h.err.clearRetainingCapacity();
        h.diag.threshold = .notice;
        return ops.systemctlArgs(&h.ctx, h.deps(), args);
    }

    pub fn stdout(h: *Harness) []const u8 {
        return h.out.written();
    }

    pub fn stderr(h: *Harness) []const u8 {
        return h.err.written();
    }

    /// Complete content of the tree, for byte-identical comparisons.
    pub fn snapshot(h: *Harness) ![]const u8 {
        var buf: Io.Writer.Allocating = .init(h.a());
        try h.walk(&buf.writer, "/");
        return buf.written();
    }

    fn walk(h: *Harness, w: *Io.Writer, dir: []const u8) !void {
        const entries = try h.fs.iterateDir(h.a(), dir);
        for (entries) |e| {
            const path = try std.fs.path.join(h.a(), &.{ dir, e.name });
            switch (e.kind) {
                .directory => {
                    try w.print("d {s}\n", .{path});
                    try h.walk(w, path);
                },
                .sym_link => {
                    var link: [std.fs.max_path_bytes]u8 = undefined;
                    try w.print("l {s} -> {s}\n", .{ path, try h.fs.readLink(path, &link) });
                },
                else => try w.print("f {s}\n{s}\n", .{ path, try h.read(path) }),
            }
        }
    }

    pub fn indexText(h: *Harness) ![]u8 {
        return h.read("/var/lib/fake-systemd/fake/index");
    }
};

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, haystack, needle) != null;
}

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (!contains(haystack, needle)) {
        std.debug.print("expected to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedContains;
    }
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (contains(haystack, needle)) {
        std.debug.print("expected NOT to find:\n{s}\nin:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedContains;
    }
}
