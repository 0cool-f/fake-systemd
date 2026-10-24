//! Diagnostics written to a caller-provided writer, filtered by a level threshold.
const std = @import("std");
const Io = std.Io;

const Diag = @This();

pub const Level = enum {
    @"error",
    warning,
    notice,
    info,

    fn label(level: Level) []const u8 {
        return switch (level) {
            .@"error" => "",
            .warning => "warning: ",
            .notice => "",
            .info => "info: ",
        };
    }
};

pub const prefix = "fake-systemd: ";

writer: *Io.Writer,
/// Least severe level that is still shown.
threshold: Level,

pub fn init(writer: *Io.Writer, threshold: Level) Diag {
    return .{ .writer = writer, .threshold = threshold };
}

pub fn err(diag: *Diag, comptime fmt: []const u8, args: anytype) void {
    diag.emit(.@"error", fmt, args);
}

pub fn warn(diag: *Diag, comptime fmt: []const u8, args: anytype) void {
    diag.emit(.warning, fmt, args);
}

pub fn notice(diag: *Diag, comptime fmt: []const u8, args: anytype) void {
    diag.emit(.notice, fmt, args);
}

pub fn info(diag: *Diag, comptime fmt: []const u8, args: anytype) void {
    diag.emit(.info, fmt, args);
}

pub fn enabled(diag: Diag, level: Level) bool {
    return @backingInt(level) <= @backingInt(diag.threshold);
}

// Write failures are dropped: stderr may be closed and there is nowhere else to report them.
fn emit(diag: *Diag, level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!diag.enabled(level)) return;
    diag.writer.print(prefix ++ "{s}" ++ fmt ++ "\n", .{level.label()} ++ args) catch return;
    diag.writer.flush() catch return;
}

fn expectOutput(threshold: Level, expected: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var diag: Diag = .init(&w, threshold);
    diag.err("e{d}", .{1});
    diag.warn("w", .{});
    diag.notice("n", .{});
    diag.info("i", .{});
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "default threshold hides info" {
    try expectOutput(.notice,
        \\fake-systemd: e1
        \\fake-systemd: warning: w
        \\fake-systemd: n
        \\
    );
}

test "quiet threshold hides notice and info" {
    try expectOutput(.warning,
        \\fake-systemd: e1
        \\fake-systemd: warning: w
        \\
    );
}

test "verbose threshold shows everything" {
    try expectOutput(.info,
        \\fake-systemd: e1
        \\fake-systemd: warning: w
        \\fake-systemd: n
        \\fake-systemd: info: i
        \\
    );
}

test "write failure does not propagate" {
    var buf: [4]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var diag: Diag = .init(&w, .info);
    diag.err("a message longer than the buffer", .{});
}
