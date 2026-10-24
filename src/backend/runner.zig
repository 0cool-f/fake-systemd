//! Process execution used by backends for runtime operations: real, dry-run and recording variants.
const std = @import("std");
const Io = std.Io;

pub const Stdio = enum { inherit, capture };

pub const Result = struct {
    /// Exit status; 128 + signal number when the process was killed.
    code: u8,
    /// Captured standard output; empty for `.inherit`.
    stdout: []const u8 = "",
};

pub const Runner = struct {
    ptr: *anyopaque,
    run_fn: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8, stdio: Stdio) anyerror!Result,

    pub fn run(r: Runner, gpa: std.mem.Allocator, argv: []const []const u8, stdio: Stdio) anyerror!Result {
        return r.run_fn(r.ptr, gpa, argv, stdio);
    }
};

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal, .stopped => |s| @intCast(128 +% @as(u8, @truncate(@backingInt(s)))),
        .unknown => 255,
    };
}

/// Spawns processes. `out` is flushed before each spawn so child output stays ordered.
pub const Real = struct {
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,

    pub fn runner(r: *Real) Runner {
        return .{ .ptr = r, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, gpa: std.mem.Allocator, argv: []const []const u8, stdio: Stdio) anyerror!Result {
        const r: *Real = @ptrCast(@alignCast(ptr));
        try r.out.flush();
        try r.err.flush();
        switch (stdio) {
            .inherit => {
                var child = try std.process.spawn(r.io, .{ .argv = argv });
                return .{ .code = termCode(try child.wait(r.io)) };
            },
            .capture => {
                const res = try std.process.run(gpa, r.io, .{ .argv = argv });
                try r.err.writeAll(res.stderr);
                return .{ .code = termCode(res.term), .stdout = res.stdout };
            },
        }
    }
};

/// Prints `would run: <argv>` to `out` and reports success without executing anything.
pub const Dry = struct {
    out: *Io.Writer,

    pub fn runner(d: *Dry) Runner {
        return .{ .ptr = d, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: Stdio) anyerror!Result {
        const d: *Dry = @ptrCast(@alignCast(ptr));
        try d.out.writeAll("would run:");
        for (argv) |word| {
            try d.out.writeByte(' ');
            try writeWord(d.out, word);
        }
        try d.out.writeByte('\n');
        return .{ .code = 0 };
    }
};

fn writeWord(w: *Io.Writer, word: []const u8) Io.Writer.Error!void {
    const plain = word.len > 0 and std.mem.findAny(u8, word, " \t\n'\"\\$") == null;
    if (plain) return w.writeAll(word);
    try w.writeByte('\'');
    for (word) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// Records every call; each call returns `code` and `stdout`.
pub const Recording = struct {
    gpa: std.mem.Allocator,
    calls: std.ArrayList([]const []const u8) = .empty,
    code: u8 = 0,
    stdout: []const u8 = "",

    pub fn runner(r: *Recording) Runner {
        return .{ .ptr = r, .run_fn = runFn };
    }

    fn runFn(ptr: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, _: Stdio) anyerror!Result {
        const r: *Recording = @ptrCast(@alignCast(ptr));
        const copy = try r.gpa.alloc([]const u8, argv.len);
        for (argv, copy) |word, *dst| dst.* = try r.gpa.dupe(u8, word);
        try r.calls.append(r.gpa, copy);
        return .{ .code = r.code, .stdout = r.stdout };
    }

    /// True when call `index` equals `expected`.
    pub fn callIs(r: Recording, index: usize, expected: []const []const u8) bool {
        if (index >= r.calls.items.len) return false;
        const call = r.calls.items[index];
        if (call.len != expected.len) return false;
        for (call, expected) |a, b| if (!std.mem.eql(u8, a, b)) return false;
        return true;
    }
};

test "dry runner prints quoted argv" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dry = .{ .out = &w };
    const res = try d.runner().run(std.testing.allocator, &.{ "ctl", "start", "a b", "" }, .inherit);
    try std.testing.expectEqual(@as(u8, 0), res.code);
    try std.testing.expectEqualStrings("would run: ctl start 'a b' ''\n", w.buffered());
}

test "recording runner keeps calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var rec: Recording = .{ .gpa = arena.allocator(), .code = 3 };
    const res = try rec.runner().run(arena.allocator(), &.{ "x", "y" }, .capture);
    try std.testing.expectEqual(@as(u8, 3), res.code);
    try std.testing.expect(rec.callIs(0, &.{ "x", "y" }));
    try std.testing.expect(!rec.callIs(1, &.{}));
}
