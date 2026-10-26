// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading Shepherd files and tool output: the command and identity of a service defined in
//! Scheme, its requirements, and the state of a service from `herd status`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");

// ---- Scheme ----------------------------------------------------------------------------

fn skipSpace(text: []const u8, i: usize) usize {
    var p = i;
    while (p < text.len and std.mem.findScalar(u8, " \t\r\n", text[p]) != null) p += 1;
    return p;
}

/// The string literal at `pos.*`, unescaped; moves `pos` behind it.
fn readString(gpa: Allocator, text: []const u8, pos: *usize) Allocator.Error!?[]const u8 {
    var i = pos.*;
    if (i >= text.len or text[i] != '"') return null;
    i += 1;
    var out: std.ArrayList(u8) = .empty;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => {
                pos.* = i + 1;
                return try out.toOwnedSlice(gpa);
            },
            '\\' => {
                i += 1;
                if (i >= text.len) return null;
                try out.append(gpa, switch (text[i]) {
                    'n' => '\n',
                    't' => '\t',
                    else => text[i],
                });
            },
            else => try out.append(gpa, text[i]),
        }
    }
    return null;
}

/// The string literals of the list at `pos`, which is `'(` or `(list`, up to its closing paren.
fn readStringList(gpa: Allocator, text: []const u8, start: usize) Allocator.Error!?[]const []const u8 {
    var i = skipSpace(text, start);
    if (std.mem.startsWith(u8, text[i..], "'(")) {
        i += 2;
    } else if (std.mem.startsWith(u8, text[i..], "(list")) {
        i += "(list".len;
    } else return null;
    var words: std.ArrayList([]const u8) = .empty;
    while (true) {
        i = skipSpace(text, i);
        if (i >= text.len) return null;
        if (text[i] == ')') break;
        const word = (try readString(gpa, text, &i)) orelse return null;
        try words.append(gpa, word);
    }
    return if (words.items.len == 0) null else try words.toOwnedSlice(gpa);
}

const command_markers = [_][]const u8{ "make-forkexec-constructor", "spawn-command" };

/// Command words of the first `make-forkexec-constructor` or `spawn-command` that is given a
/// literal list of strings.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var best: ?usize = null;
    for (command_markers) |m| {
        if (std.mem.find(u8, content, m)) |at| {
            if (best == null or at < best.?) best = at;
        }
    }
    var from = best orelse return null;
    while (true) {
        for (command_markers) |m| {
            if (std.mem.startsWith(u8, content[from..], m)) {
                if (try readStringList(gpa, content, from + m.len)) |words| return words;
            }
        }
        from = std.mem.findPos(u8, content, from + 1, "make-forkexec-constructor") orelse return null;
    }
}

fn readSymbol(text: []const u8, pos: *usize) ?[]const u8 {
    const i = skipSpace(text, pos.*);
    if (i >= text.len) return null;
    if (std.mem.startsWith(u8, text[i..], "#{")) {
        const end = std.mem.find(u8, text[i..], "}#") orelse return null;
        pos.* = i + end + 2;
        return text[i + 2 .. i + end];
    }
    const end = std.mem.findAnyPos(u8, text, i, " \t\r\n()'") orelse text.len;
    if (end == i) return null;
    pos.* = end;
    return text[i..end];
}

fn symbolsAfter(gpa: Allocator, content: []const u8, key: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const at = std.mem.find(u8, content, key) orelse return &.{};
    var i = skipSpace(content, at + key.len);
    if (!std.mem.startsWith(u8, content[i..], "'(")) return &.{};
    i += 2;
    while (readSymbol(content, &i)) |sym| try out.append(gpa, sym);
    return out.toOwnedSlice(gpa);
}

/// The first name a service defined in `content` provides, which `herd` takes.
pub fn identityOf(gpa: Allocator, content: []const u8) Allocator.Error!?[]const u8 {
    for ([_][]const u8{ "(provision", "(service" }) |key| {
        const names = try symbolsAfter(gpa, content, key);
        if (names.len > 0) return names[0];
    }
    return null;
}

/// The services named in `#:requirement`.
pub fn requirementsOf(gpa: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    return symbolsAfter(gpa, content, "#:requirement");
}

/// The `setpriv` switch in front of the executor of a generated service.
pub const Wrapper = struct {
    path: []const u8,
    user: []const u8,
    /// The group named in the file; null when it is looked up for the account.
    group: ?[]const u8,
};

/// Reads the switch the renderer writes: `(list "<setpriv>" "--reuid=<user>" <regid> "--init-groups" ...`.
pub fn wrapperOf(gpa: Allocator, content: []const u8) Allocator.Error!?Wrapper {
    const at = std.mem.find(u8, content, "(list \"") orelse return null;
    var i = at + "(list ".len;
    const path = (try readString(gpa, content, &i)) orelse return null;
    if (!std.mem.endsWith(u8, path, "setpriv")) return null;
    i = skipSpace(content, i);
    const reuid = (try readString(gpa, content, &i)) orelse return null;
    const user = std.mem.cutPrefix(u8, reuid, "--reuid=") orelse return null;
    i = skipSpace(content, i);
    if (i < content.len and content[i] == '"') {
        const regid = (try readString(gpa, content, &i)) orelse return null;
        const group = std.mem.cutPrefix(u8, regid, "--regid=") orelse return null;
        return .{ .path = path, .user = user, .group = group };
    }
    return .{ .path = path, .user = user, .group = null };
}

// ---- status ----------------------------------------------------------------------------

pub const Run = enum { unknown, running, starting, stopping, stopped, failing };

pub const Ended = union(enum) {
    none,
    code: u8,
    signal: u8,
};

pub const Parsed = struct {
    run: Run = .unknown,
    ended: Ended = .none,
    pid: ?u32 = null,
    disabled: bool = false,
};

fn lineTail(line: []const u8, prefix: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    return std.mem.cutPrefix(u8, t, prefix);
}

fn leadingNumber(text: []const u8) ?u8 {
    const end = std.mem.findNone(u8, text, "0123456789") orelse text.len;
    return std.fmt.parseInt(u8, text[0..end], 10) catch null;
}

/// Reads the lines of `herd status <name>`.
pub fn parseStatus(text: []const u8) Parsed {
    var out: Parsed = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (lineTail(line, "It is running since") != null or lineTail(line, "It is transient, running since") != null or
            lineTail(line, "It is started") != null) out.run = .running;
        if (lineTail(line, "It is starting") != null) out.run = .starting;
        if (lineTail(line, "It is being stopped") != null) out.run = .stopping;
        if (lineTail(line, "It is stopped")) |rest| out.run = if (std.mem.startsWith(u8, rest, " (failing)")) .failing else .stopped;
        if (lineTail(line, "It is disabled") != null) out.disabled = true;
        if (lineTail(line, "Main PID: ")) |n| out.pid = std.fmt.parseInt(u32, std.mem.trim(u8, n, " "), 10) catch null;
        if (lineTail(line, "Process exited with code ")) |n| if (leadingNumber(n)) |c| {
            out.ended = .{ .code = c };
        };
        if (lineTail(line, "Process exited successfully") != null) out.ended = .{ .code = 0 };
        if (lineTail(line, "Process terminated with signal ")) |n| if (leadingNumber(n)) |s| {
            out.ended = .{ .signal = s };
        };
    }
    return out;
}

/// Normalized state. A process that ended by a stop signal is not a failure.
pub fn stateOf(p: Parsed) output.ActiveState {
    return switch (p.run) {
        .running => .active,
        .starting => .activating,
        .stopping => .deactivating,
        .failing => .failed,
        .unknown => .inactive,
        .stopped => switch (p.ended) {
            .none => .inactive,
            .code => |c| if (c == 0) .inactive else .failed,
            .signal => |s| switch (s) {
                1, 2, 13, 15 => .inactive,
                else => .failed,
            },
        },
    };
}

/// True when `herd` answered that no service has the name.
pub fn isMissing(stderr_or_out: []const u8) bool {
    return std.mem.find(u8, stderr_or_out, "could not be found") != null;
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the command is the first literal list given to a constructor" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/crond", "-n" }, try extractCommand(a, "(service '(crond) #:start (make-forkexec-constructor '(\"/usr/bin/crond\" \"-n\") #:user \"root\"))"));
    try expectWords(&.{ "/bin/sh", "-c", "a \"b\"" }, try extractCommand(a, "#:start (make-forkexec-constructor (list \"/bin/sh\" \"-c\" \"a \\\"b\\\"\"))"));
    try expectWords(&.{ "/usr/bin/fake-systemd", "--exec", "x.service" }, try extractCommand(a, "#:start (lambda _ (spawn-command '(\"/usr/bin/fake-systemd\" \"--exec\" \"x.service\")))"));
    try testing.expect(try extractCommand(a, "(make-forkexec-constructor (compute-command))") == null);
    try testing.expect(try extractCommand(a, "(service '(x))") == null);
}

test "identity and requirements are read from the definition" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "(register-services (list (service '(foo bar)\n  #:requirement '(dbus #{weird name}# pg)\n  #:start x)))";
    try testing.expectEqualStrings("foo", (try identityOf(a, text)).?);
    const reqs = try requirementsOf(a, text);
    try testing.expectEqual(@as(usize, 3), reqs.len);
    try testing.expectEqualStrings("weird name", reqs[1]);
    try testing.expectEqualStrings("nginx", (try identityOf(a, "(shepherd-service (provision '(nginx)) (start x))")).?);
    try testing.expect(try identityOf(a, "(define x 1)") == null);
    try testing.expectEqual(@as(usize, 0), (try requirementsOf(a, "(service '(x) #:requirement '())")).len);
}

fn expectState(state: output.ActiveState, pid: ?u32, text: []const u8) !void {
    const p = parseStatus(text);
    try testing.expectEqual(state, stateOf(p));
    try testing.expectEqual(pid, p.pid);
}

test "statuses observed from shepherd 1.0.3 map to systemd states" {
    try expectState(.active, 67, "Status of foo:\n  It is running since 19:22:04 (1 second ago).\n  Main PID: 67\n  Command: /bin/sh\n  It is enabled.\n");
    try expectState(.active, null, "Status of foo:\n  It is started.\n  It is enabled.\n");
    try expectState(.inactive, null, "Status of foo:\n  It is stopped.\n  It is enabled.\n");
    try expectState(.inactive, null, "Status of foo:\n  It is stopped since 19:22:05 (0 seconds ago).\n  Process terminated with signal 15.\n  It is enabled.\n");
    try expectState(.failed, null, "Status of bad:\n  It is stopped since 19:23:01 (1 second ago).\n  Process exited with code 3.\n  It is disabled.\n");
    try expectState(.inactive, null, "Status of ok:\n  It is stopped since 19:23:01 (1 second ago).\n  Process exited successfully.\n");
    try expectState(.failed, null, "Status of crash:\n  It is stopped since 19:23:01.\n  Process terminated with signal 11.\n");
    try expectState(.inactive, null, "Status of once:\n  It is stopped (one-shot).\n  It is enabled.\n");
    try expectState(.failed, null, "Status of x:\n  It is stopped (failing).\n");
    try expectState(.activating, null, "Status of x:\n  It is starting.\n");
    try expectState(.deactivating, 9, "Status of x:\n  It is being stopped.\n  Main PID: 9\n");
    try expectState(.inactive, null, "");
    try testing.expect(parseStatus("Status of x:\n  It is stopped.\n  It is disabled.\n").disabled);
}

test "a missing service is recognised" {
    try testing.expect(isMissing("herd: error: service 'nosuch' could not be found\n"));
    try testing.expect(!isMissing("Status of foo:\n"));
}

test "the setpriv switch of a generated file is read back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const looked_up = "(apply (make-forkexec-constructor (list \"/usr/bin/setpriv\" \"--reuid=ldap\" (string-append \"--regid=\" (number->string (passwd:gid (getpw \"ldap\")))) \"--init-groups\" \"/x\")) args)";
    const w = (try wrapperOf(a, looked_up)).?;
    try testing.expectEqualStrings("/usr/bin/setpriv", w.path);
    try testing.expectEqualStrings("ldap", w.user);
    try testing.expect(w.group == null);
    const named = (try wrapperOf(a, "(list \"/usr/bin/setpriv\" \"--reuid=ldap\" \"--regid=staff\" \"--init-groups\")")).?;
    try testing.expectEqualStrings("staff", named.group.?);
    try testing.expect(try wrapperOf(a, "'(\"/usr/bin/fake-systemd\")") == null);
    try testing.expect(try wrapperOf(a, "(list \"/bin/sh\" \"--reuid=x\")") == null);
}
