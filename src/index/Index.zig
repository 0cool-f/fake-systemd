//! In-memory index of generated units, native services and timers, with the v2 text format (§7.4).
//! Every slice stored in an index must outlive it; use one arena per invocation.
const std = @import("std");
const Io = std.Io;
const Fs = @import("../core/Fs.zig");
const Diag = @import("../core/Diag.zig");
const types = @import("../core/types.zig");
const hash = @import("hash.zig");

const Index = @This();

pub const format_version = 2;

pub const State = enum { managed, native, missing };

pub const FileEntry = struct {
    path: []const u8,
    out_hash: u64,
    stat: u64,
};

pub const Unit = struct {
    name: []const u8,
    scope: types.Scope,
    tier: types.Tier,
    state: State,
    src_hash: u64,
    src_stat: u64,
    files: []const FileEntry,
    generator_version: []const u8,

    pub fn findFile(u: Unit, path: []const u8) ?FileEntry {
        for (u.files) |f| if (std.mem.eql(u8, f.path, path)) return f;
        return null;
    }
};

pub const Native = struct {
    name: []const u8,
    path: []const u8,
    file_hash: u64,
    file_stat: u64,
    exec: []const u8,
};

pub const Timer = struct {
    name: []const u8,
    /// `cron:<adapter>` or `builtin`.
    scheduler: []const u8,
    src_hash: u64,
    src_stat: u64,
    /// Unix seconds.
    last_trigger: ?i64,
    next_trigger: ?i64,
};

pub const LoadStatus = enum {
    ok,
    /// Entries are valid but were written by another generator version.
    generator_changed,
    /// Header missing, unknown version, other backend or unreadable file: the index is empty.
    rebuild_needed,
};

pub const Loaded = struct {
    index: Index,
    status: LoadStatus,
    /// Number of malformed lines dropped.
    dropped: usize = 0,
};

backend: []const u8,
generator: u32,
units: std.ArrayList(Unit) = .empty,
natives: std.ArrayList(Native) = .empty,
timers: std.ArrayList(Timer) = .empty,

pub fn init(backend: []const u8, generator: u32) Index {
    return .{ .backend = backend, .generator = generator };
}

fn indexOfName(comptime T: type, items: []const T, name: []const u8) ?usize {
    for (items, 0..) |item, i| if (std.mem.eql(u8, item.name, name)) return i;
    return null;
}

fn putByName(comptime T: type, arena: std.mem.Allocator, list: *std.ArrayList(T), value: T) !void {
    if (indexOfName(T, list.items, value.name)) |i| {
        list.items[i] = value;
    } else {
        try list.append(arena, value);
    }
}

fn removeByName(comptime T: type, list: *std.ArrayList(T), name: []const u8) bool {
    const i = indexOfName(T, list.items, name) orelse return false;
    _ = list.orderedRemove(i);
    return true;
}

pub fn findUnit(index: *Index, name: []const u8) ?*Unit {
    const i = indexOfName(Unit, index.units.items, name) orelse return null;
    return &index.units.items[i];
}

pub fn putUnit(index: *Index, arena: std.mem.Allocator, unit: Unit) !void {
    try putByName(Unit, arena, &index.units, unit);
}

pub fn removeUnit(index: *Index, name: []const u8) bool {
    return removeByName(Unit, &index.units, name);
}

pub fn findNative(index: *Index, name: []const u8) ?*Native {
    const i = indexOfName(Native, index.natives.items, name) orelse return null;
    return &index.natives.items[i];
}

pub fn putNative(index: *Index, arena: std.mem.Allocator, native: Native) !void {
    try putByName(Native, arena, &index.natives, native);
}

pub fn removeNative(index: *Index, name: []const u8) bool {
    return removeByName(Native, &index.natives, name);
}

pub fn findTimer(index: *Index, name: []const u8) ?*Timer {
    const i = indexOfName(Timer, index.timers.items, name) orelse return null;
    return &index.timers.items[i];
}

pub fn putTimer(index: *Index, arena: std.mem.Allocator, timer: Timer) !void {
    try putByName(Timer, arena, &index.timers, timer);
}

pub fn removeTimer(index: *Index, name: []const u8) bool {
    return removeByName(Timer, &index.timers, name);
}

// ---- escaping ----

fn needsEscape(c: u8, comma: bool) bool {
    return c < 0x20 or c == 0x7f or c == '%' or (comma and c == ',');
}

fn writeEscaped(w: *Io.Writer, s: []const u8, comma: bool) Io.Writer.Error!void {
    for (s) |c| {
        if (needsEscape(c, comma)) {
            try w.print("%{X:0>2}", .{c});
        } else {
            try w.writeByte(c);
        }
    }
}

fn unescape(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') {
            try out.append(arena, s[i]);
            continue;
        }
        if (i + 3 > s.len) return error.BadEscape;
        const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.BadEscape;
        const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.BadEscape;
        const byte = hi * 16 + lo;
        try out.append(arena, byte);
        i += 2;
    }
    return out.items;
}

// ---- rendering ----

fn writeText(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try writeEscaped(w, s, false);
}

fn writeOptInt(w: *Io.Writer, v: ?i64) Io.Writer.Error!void {
    if (v) |n| try w.print("{d}", .{n}) else try w.writeByte('-');
}

pub fn render(index: Index, w: *Io.Writer) Io.Writer.Error!void {
    try w.print("# fake-systemd index v{d} backend={s} generator={d}\n", .{ format_version, index.backend, index.generator });
    for (index.units.items) |u| {
        try w.writeAll("unit\t");
        try writeText(w, u.name);
        try w.print("\t{t}\t{t}\t{t}\t{f}\t{f}\t", .{ u.scope, u.tier, u.state, hash.str(u.src_hash), hash.str(u.src_stat) });
        for (u.files, 0..) |f, i| {
            if (i != 0) try w.writeByte(',');
            try writeEscaped(w, f.path, true);
            try w.print("={f}:{f}", .{ hash.str(f.out_hash), hash.str(f.stat) });
        }
        try w.writeByte('\t');
        try writeText(w, u.generator_version);
        try w.writeByte('\n');
    }
    for (index.natives.items) |n| {
        try w.writeAll("native\t");
        try writeText(w, n.name);
        try w.writeByte('\t');
        try writeText(w, n.path);
        try w.print("\t{f}\t{f}\t", .{ hash.str(n.file_hash), hash.str(n.file_stat) });
        try writeText(w, n.exec);
        try w.writeByte('\n');
    }
    for (index.timers.items) |t| {
        try w.writeAll("timer\t");
        try writeText(w, t.name);
        try w.writeByte('\t');
        try writeText(w, t.scheduler);
        try w.print("\t{f}\t{f}\t", .{ hash.str(t.src_hash), hash.str(t.src_stat) });
        try writeOptInt(w, t.last_trigger);
        try w.writeByte('\t');
        try writeOptInt(w, t.next_trigger);
        try w.writeByte('\n');
    }
}

/// Atomically writes the index to `path`, creating parent directories.
pub fn save(index: Index, gpa: std.mem.Allocator, fs: Fs, path: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try index.render(&aw.writer);
    try fs.makePath(std.fs.path.dirname(path) orelse "/");
    try fs.writeFileAtomic(path, aw.written(), 0o644);
}

// ---- parsing ----

const LineError = error{
    UnknownType,
    WrongFieldCount,
    BadHash,
    BadNumber,
    BadEscape,
    BadValue,
    BadFileList,
    OutOfMemory,
};

const max_fields = 9;

fn splitFields(line: []const u8, buf: *[max_fields][]const u8) LineError![]const []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (n == max_fields) return error.WrongFieldCount;
        buf[n] = f;
        n += 1;
    }
    return buf[0..n];
}

fn hashField(s: []const u8) LineError!u64 {
    return hash.parse(s) orelse error.BadHash;
}

fn textField(arena: std.mem.Allocator, s: []const u8) LineError![]const u8 {
    return unescape(arena, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadEscape => error.BadEscape,
    };
}

fn enumField(comptime E: type, s: []const u8) LineError!E {
    return std.meta.stringToEnum(E, s) orelse error.BadValue;
}

fn optIntField(s: []const u8) LineError!?i64 {
    if (std.mem.eql(u8, s, "-")) return null;
    return std.fmt.parseInt(i64, s, 10) catch error.BadNumber;
}

fn parseFileList(arena: std.mem.Allocator, s: []const u8) LineError![]const FileEntry {
    var list: std.ArrayList(FileEntry) = .empty;
    if (s.len == 0) return list.items;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |item| {
        const eq = std.mem.findScalarLast(u8, item, '=') orelse return error.BadFileList;
        const value = item[eq + 1 ..];
        if (value.len != hash.string_len * 2 + 1 or value[hash.string_len] != ':') return error.BadFileList;
        try list.append(arena, .{
            .path = try textField(arena, item[0..eq]),
            .out_hash = try hashField(value[0..hash.string_len]),
            .stat = try hashField(value[hash.string_len + 1 ..]),
        });
    }
    return list.items;
}

fn parseLine(index: *Index, arena: std.mem.Allocator, line: []const u8) LineError!void {
    var buf: [max_fields][]const u8 = undefined;
    const f = try splitFields(line, &buf);
    if (std.mem.eql(u8, f[0], "unit")) {
        if (f.len != 9) return error.WrongFieldCount;
        try index.putUnit(arena, .{
            .name = try textField(arena, f[1]),
            .scope = try enumField(types.Scope, f[2]),
            .tier = try enumField(types.Tier, f[3]),
            .state = try enumField(State, f[4]),
            .src_hash = try hashField(f[5]),
            .src_stat = try hashField(f[6]),
            .files = try parseFileList(arena, f[7]),
            .generator_version = try textField(arena, f[8]),
        });
    } else if (std.mem.eql(u8, f[0], "native")) {
        if (f.len != 6) return error.WrongFieldCount;
        try index.putNative(arena, .{
            .name = try textField(arena, f[1]),
            .path = try textField(arena, f[2]),
            .file_hash = try hashField(f[3]),
            .file_stat = try hashField(f[4]),
            .exec = try textField(arena, f[5]),
        });
    } else if (std.mem.eql(u8, f[0], "timer")) {
        if (f.len != 7) return error.WrongFieldCount;
        try index.putTimer(arena, .{
            .name = try textField(arena, f[1]),
            .scheduler = try textField(arena, f[2]),
            .src_hash = try hashField(f[3]),
            .src_stat = try hashField(f[4]),
            .last_trigger = try optIntField(f[5]),
            .next_trigger = try optIntField(f[6]),
        });
    } else {
        return error.UnknownType;
    }
}

const Header = struct { version: u32, backend: []const u8, generator: u32 };

fn parseHeader(line: []const u8) ?Header {
    const lead = "# fake-systemd index v";
    if (!std.mem.startsWith(u8, line, lead)) return null;
    var it = std.mem.tokenizeScalar(u8, line[lead.len..], ' ');
    const version = std.fmt.parseUnsigned(u32, it.next() orelse return null, 10) catch return null;
    const backend_kv = it.next() orelse return null;
    const generator_kv = it.next() orelse return null;
    if (!std.mem.startsWith(u8, backend_kv, "backend=") or !std.mem.startsWith(u8, generator_kv, "generator=")) return null;
    const generator = std.fmt.parseUnsigned(u32, generator_kv["generator=".len..], 10) catch return null;
    return .{ .version = version, .backend = backend_kv["backend=".len..], .generator = generator };
}

/// Parses index text. Malformed lines are dropped with an info diagnostic; entries are
/// then recovered from markers by the caller (see `rebuild`).
pub fn parse(arena: std.mem.Allocator, diag: *Diag, text: []const u8, backend: []const u8, generator: u32) !Loaded {
    var index = init(backend, generator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    const header = parseHeader(lines.first()) orelse {
        diag.info("index header missing or malformed, rebuilding from markers", .{});
        return .{ .index = index, .status = .rebuild_needed };
    };
    if (header.version != format_version) {
        diag.info("index format version {d} is not supported, rebuilding from markers", .{header.version});
        return .{ .index = index, .status = .rebuild_needed };
    }
    if (!std.mem.eql(u8, header.backend, backend)) {
        diag.info("index belongs to backend {s}, rebuilding from markers", .{header.backend});
        return .{ .index = index, .status = .rebuild_needed };
    }
    var dropped: usize = 0;
    var line_no: usize = 1;
    while (lines.next()) |line| {
        line_no += 1;
        if (line.len == 0 or line[0] == '#') continue;
        parseLine(&index, arena, line) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                dropped += 1;
                diag.info("index line {d} dropped: {t}", .{ line_no, e });
            },
        };
    }
    return .{
        .index = index,
        .status = if (header.generator == generator) .ok else .generator_changed,
        .dropped = dropped,
    };
}

/// Reads and parses the index at `path`; a missing or unreadable file reports `rebuild_needed`.
pub fn load(arena: std.mem.Allocator, fs: Fs, diag: *Diag, path: []const u8, backend: []const u8, generator: u32) !Loaded {
    const text = fs.readFileAlloc(arena, path, 64 << 20) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            diag.info("index {s} unreadable ({t}), rebuilding from markers", .{ path, e });
            return .{ .index = init(backend, generator), .status = .rebuild_needed };
        },
    };
    return parse(arena, diag, text, backend, generator);
}

const testing = std.testing;

fn sampleIndex(arena: std.mem.Allocator) !Index {
    var idx = init("dinit", 1);
    try idx.putUnit(arena, .{
        .name = "foo.service",
        .scope = .system,
        .tier = .vendor,
        .state = .managed,
        .src_hash = 0x7d1f0c2a9b3e4f51,
        .src_stat = 2,
        .files = &.{
            .{ .path = "/usr/lib/dinit.d/foo", .out_hash = 3, .stat = 4 },
            .{ .path = "/usr/lib/dinit.d/foo.log", .out_hash = 5, .stat = 6 },
        },
        .generator_version = "0.1.0",
    });
    try idx.putNative(arena, .{ .name = "bar", .path = "/etc/dinit.d/bar", .file_hash = 7, .file_stat = 8, .exec = "/usr/bin/bar" });
    try idx.putTimer(arena, .{ .name = "foo.timer", .scheduler = "builtin", .src_hash = 9, .src_stat = 10, .last_trigger = 1700000000, .next_trigger = null });
    return idx;
}

fn expectDiagEmpty(w: *Io.Writer) !void {
    try testing.expectEqualStrings("", w.buffered());
}

test "render matches the spec layout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const idx = try sampleIndex(arena.allocator());
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try idx.render(&aw.writer);
    try testing.expectEqualStrings(
        "# fake-systemd index v2 backend=dinit generator=1\n" ++
            "unit\tfoo.service\tsystem\tvendor\tmanaged\txxh3:7d1f0c2a9b3e4f51\txxh3:0000000000000002\t" ++
            "/usr/lib/dinit.d/foo=xxh3:0000000000000003:xxh3:0000000000000004," ++
            "/usr/lib/dinit.d/foo.log=xxh3:0000000000000005:xxh3:0000000000000006\t0.1.0\n" ++
            "native\tbar\t/etc/dinit.d/bar\txxh3:0000000000000007\txxh3:0000000000000008\t/usr/bin/bar\n" ++
            "timer\tfoo.timer\tbuiltin\txxh3:0000000000000009\txxh3:000000000000000a\t1700000000\t-\n",
        aw.written(),
    );
}

test "round trip including hostile paths" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try sampleIndex(a);
    const weird = "/etc/d/a\tb\nc%d,e=f\r\x01é";
    try idx.putUnit(a, .{
        .name = "w.service",
        .scope = .user,
        .tier = .personal,
        .state = .missing,
        .src_hash = 1,
        .src_stat = 2,
        .files = &.{.{ .path = weird, .out_hash = 3, .stat = 4 }},
        .generator_version = "",
    });
    try idx.putNative(a, .{ .name = "n\t", .path = weird, .file_hash = 1, .file_stat = 2, .exec = "%41" });
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try idx.render(&aw.writer);
    for (aw.written()) |c| try testing.expect(c == '\n' or c == '\t' or c >= 0x20);

    var out: [256]u8 = undefined;
    var dw: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&dw, .info);
    const loaded = try parse(a, &diag, aw.written(), "dinit", 1);
    try expectDiagEmpty(&dw);
    try testing.expectEqual(LoadStatus.ok, loaded.status);
    var got = loaded.index;
    try testing.expectEqual(@as(usize, 2), got.units.items.len);
    const w = got.findUnit("w.service").?;
    try testing.expectEqualStrings(weird, w.files[0].path);
    try testing.expectEqual(State.missing, w.state);
    try testing.expectEqual(types.Tier.personal, w.tier);
    try testing.expectEqualStrings("", w.generator_version);
    const foo = got.findUnit("foo.service").?;
    try testing.expectEqual(@as(usize, 2), foo.files.len);
    try testing.expectEqual(@as(u64, 0x7d1f0c2a9b3e4f51), foo.src_hash);
    const n = got.findNative("n\t").?;
    try testing.expectEqualStrings(weird, n.path);
    try testing.expectEqualStrings("%41", n.exec);
    const t = got.findTimer("foo.timer").?;
    try testing.expectEqual(@as(?i64, 1700000000), t.last_trigger);
    try testing.expectEqual(@as(?i64, null), t.next_trigger);
}

test "malformed lines are dropped with an info diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text =
        "# fake-systemd index v2 backend=dinit generator=1\n" ++
        "bogus\tx\n" ++
        "unit\tshort\n" ++
        "native\tbar\t/p\tnot-a-hash\txxh3:0000000000000001\t/x\n" ++
        "native\tbad\t/p%zz\txxh3:0000000000000001\txxh3:0000000000000001\t/x\n" ++
        "native\tgood\t/p\txxh3:0000000000000001\txxh3:0000000000000002\t/x\n" ++
        "native\ttrunc\t/p%4\txxh3:0000000000000001\txxh3:0000000000000002\t/x\n" ++
        "timer\tt\tbuiltin\txxh3:0000000000000001\txxh3:0000000000000002\tnan\t-\n";
    var out: [1024]u8 = undefined;
    var dw: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&dw, .info);
    const loaded = try parse(arena.allocator(), &diag, text, "dinit", 1);
    try testing.expectEqual(@as(usize, 6), loaded.dropped);
    try testing.expectEqual(@as(usize, 1), loaded.index.natives.items.len);
    try testing.expectEqualStrings("good", loaded.index.natives.items[0].name);
    try testing.expect(std.mem.find(u8, dw.buffered(), "fake-systemd: info: index line 2 dropped: UnknownType\n") != null);
    try testing.expect(std.mem.find(u8, dw.buffered(), "index line 3 dropped: WrongFieldCount") != null);
}

test "header problems request a rebuild" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: [1024]u8 = undefined;
    var dw: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&dw, .info);
    for ([_][]const u8{
        "",
        "garbage\n",
        "# fake-systemd index v3 backend=dinit generator=1\n",
        "# fake-systemd index v2 backend=runit generator=1\n",
        "# fake-systemd index v2 backend=dinit\n",
    }) |text| {
        const l = try parse(a, &diag, text, "dinit", 1);
        try testing.expectEqual(LoadStatus.rebuild_needed, l.status);
        try testing.expectEqual(@as(usize, 0), l.index.units.items.len);
    }
}

test "other generator version keeps entries but is reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: [64]u8 = undefined;
    var dw: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&dw, .info);
    const l = try parse(arena.allocator(), &diag, "# fake-systemd index v2 backend=dinit generator=1\n" ++
        "native\tn\t/p\txxh3:0000000000000001\txxh3:0000000000000002\t/x\n", "dinit", 2);
    try testing.expectEqual(LoadStatus.generator_changed, l.status);
    try testing.expectEqual(@as(usize, 1), l.index.natives.items.len);
}

test "save is atomic and load reads it back; missing file asks for rebuild" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs: Fs = .initDir(testing.io, tmp.dir);
    var out: [256]u8 = undefined;
    var dw: Io.Writer = .fixed(&out);
    var diag: Diag = .init(&dw, .info);
    const path = "/var/lib/fake-systemd/dinit/index";

    const missing = try load(a, fs, &diag, path, "dinit", 1);
    try testing.expectEqual(LoadStatus.rebuild_needed, missing.status);

    const idx = try sampleIndex(a);
    try idx.save(testing.allocator, fs, path);
    try idx.save(testing.allocator, fs, path);
    const entries = try fs.iterateDir(a, "/var/lib/fake-systemd/dinit");
    try testing.expectEqual(@as(usize, 1), entries.len);
    const loaded = try load(a, fs, &diag, path, "dinit", 1);
    try testing.expectEqual(LoadStatus.ok, loaded.status);
    try testing.expectEqual(@as(usize, 1), loaded.index.units.items.len);
}

test "put replaces by name and remove deletes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var idx = try sampleIndex(a);
    var u = idx.findUnit("foo.service").?.*;
    u.state = .native;
    try idx.putUnit(a, u);
    try testing.expectEqual(@as(usize, 1), idx.units.items.len);
    try testing.expectEqual(State.native, idx.findUnit("foo.service").?.state);
    try testing.expect(idx.removeUnit("foo.service"));
    try testing.expect(!idx.removeUnit("foo.service"));
    try testing.expect(idx.removeNative("bar"));
    try testing.expect(idx.removeTimer("foo.timer"));
}
