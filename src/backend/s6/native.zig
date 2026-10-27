// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading s6 files and tool output: the command of a `run` script (sh) or of a `run` or `up`
//! file (execline), the settings recorded in a generated script, and the state of a service
//! from `s6-svstat`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");
const interface = @import("../interface.zig");
const runit_native = @import("../runit/native.zig");

// ---- execline ----------------------------------------------------------------------------

const Token = struct {
    text: []const u8,
    kind: enum { word, open, close },
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Splits execline source into words and block delimiters. Comments start at a word boundary,
/// double quotes group a word and a backslash escapes the next character inside them; a quoted
/// `{` or `}` is a plain word.
fn tokenize(gpa: Allocator, content: []const u8) Allocator.Error![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (isSpace(c)) {
            i += 1;
        } else if (c == '#') {
            while (i < content.len and content[i] != '\n') i += 1;
        } else {
            var word: std.ArrayList(u8) = .empty;
            var quoted = false;
            while (i < content.len and !isSpace(content[i])) {
                if (content[i] == '"') {
                    quoted = true;
                    i += 1;
                    while (i < content.len and content[i] != '"') {
                        if (content[i] == '\\' and i + 1 < content.len) {
                            i += 1;
                            try word.append(gpa, switch (content[i]) {
                                'n' => '\n',
                                't' => '\t',
                                'r' => '\r',
                                else => content[i],
                            });
                        } else try word.append(gpa, content[i]);
                        i += 1;
                    }
                    i += 1;
                } else if (content[i] == '\\' and i + 1 < content.len) {
                    try word.append(gpa, content[i + 1]);
                    i += 2;
                } else {
                    try word.append(gpa, content[i]);
                    i += 1;
                }
            }
            const text = try word.toOwnedSlice(gpa);
            const kind: @FieldType(Token, "kind") = if (!quoted and std.mem.eql(u8, text, "{")) .open else if (!quoted and std.mem.eql(u8, text, "}")) .close else .word;
            try tokens.append(gpa, .{ .text = text, .kind = kind });
        }
    }
    return tokens.toOwnedSlice(gpa);
}

/// How many options, positional words and blocks an execline program takes before the program
/// it runs next. `valued` options take the following word.
const Chain = struct {
    name: []const u8,
    valued: []const []const u8 = &.{},
    words: u8 = 0,
    blocks: u8 = 0,
};

const chain_programs = [_]Chain{
    .{ .name = "foreground", .blocks = 1 },
    .{ .name = "background", .blocks = 1 },
    .{ .name = "if", .blocks = 1 },
    .{ .name = "ifelse", .blocks = 2 },
    .{ .name = "ifthenelse", .blocks = 3 },
    .{ .name = "pipeline", .blocks = 1 },
    .{ .name = "multisubstitute", .blocks = 1 },
    .{ .name = "backtick", .valued = &.{"-D"}, .words = 1, .blocks = 1 },
    .{ .name = "fdmove", .words = 2 },
    .{ .name = "redirfd", .words = 2 },
    .{ .name = "export", .words = 2 },
    .{ .name = "unexport", .words = 1 },
    .{ .name = "define", .words = 2 },
    .{ .name = "cd", .words = 1 },
    .{ .name = "umask", .words = 1 },
    .{ .name = "emptyenv" },
    .{ .name = "exec", .valued = &.{"-a"} },
    .{ .name = "envfile", .words = 1 },
    .{ .name = "importas", .valued = &.{"-D"}, .words = 2 },
    .{ .name = "s6-envdir", .words = 1 },
    .{ .name = "s6-setuidgid", .words = 1 },
    .{ .name = "s6-envuidgid", .valued = &.{"-D"}, .words = 1 },
    .{ .name = "s6-applyuidgid", .valued = &.{ "-u", "-g", "-G" } },
    .{ .name = "s6-softlimit", .valued = &.{ "-a", "-c", "-d", "-f", "-l", "-m", "-o", "-p", "-r", "-s", "-t" } },
};

fn findChain(name: []const u8) ?Chain {
    for (chain_programs) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, item)) return true;
    return false;
}

/// Words an option cluster such as `-sCuD` takes: one, plus the next word when its last letter is
/// an option with a value, which a letter in the middle of the cluster takes from the rest of it.
fn optionWords(valued: []const []const u8, word: []const u8) usize {
    const last = word[word.len - 1];
    for (valued) |v| {
        if (v.len == 2 and v[1] == last and word.len > 1) return 2;
    }
    return 1;
}

/// Index after the block that opens at `tokens[start]`, or null when it never closes.
fn skipBlock(tokens: []const Token, start: usize) ?usize {
    if (start >= tokens.len or tokens[start].kind != .open) return null;
    var depth: usize = 0;
    var i = start;
    while (i < tokens.len) : (i += 1) {
        switch (tokens[i].kind) {
            .open => depth += 1,
            .close => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            .word => {},
        }
    }
    return null;
}

/// Command words of an execline script: the program at the end of the chain of the top-level
/// command line, past the programs that only prepare the environment of the next one. Blocks
/// are skipped, so with `ifelse` the else branch, which follows the blocks, is the chain.
pub fn extractExecline(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    const tokens = try tokenize(gpa, content);
    var i: usize = 0;
    while (i < tokens.len) {
        if (tokens[i].kind != .word) return null;
        const chain = findChain(std.fs.path.basename(tokens[i].text)) orelse return try words(gpa, tokens[i..]);
        i += 1;
        while (i < tokens.len and tokens[i].kind == .word and tokens[i].text.len > 1 and tokens[i].text[0] == '-') {
            i += optionWords(chain.valued, tokens[i].text);
        }
        i += chain.words;
        var b: u8 = 0;
        while (b < chain.blocks) : (b += 1) i = skipBlock(tokens, i) orelse return null;
    }
    return null;
}

fn words(gpa: Allocator, tokens: []const Token) Allocator.Error!?[]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (tokens) |t| {
        if (t.kind != .word) break;
        try out.append(gpa, t.text);
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(gpa);
}

fn isExecline(content: []const u8) bool {
    if (!std.mem.startsWith(u8, content, "#!")) return true;
    const end = std.mem.findScalar(u8, content, '\n') orelse content.len;
    return std.mem.find(u8, content[0..end], "execlineb") != null;
}

/// Command words of a `run` or `up` file: execline, unless a shebang names another interpreter,
/// where the last `exec` line gives them.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    if (isExecline(content)) return extractExecline(gpa, content);
    return runit_native.extractCommand(gpa, content);
}

// ---- settings recorded in generated scripts --------------------------------------------------

pub const flags_prefix = "# fake-systemd flags:";

/// Settings that the commands of the backend read back from a generated `run` or `up`.
pub const Flags = struct {
    /// `ExecStop=` commands exist and run through the executor before the process is signalled.
    exec_stop: bool = false,
    /// A oneshot stays active once its command has succeeded.
    remain: bool = false,
    /// A oneshot that ends by itself: starting it waits until its command and `finish` are done.
    oneshot: bool = false,
    /// `TimeoutStartSec=` of that oneshot in milliseconds, 0 for none; null for the default.
    start_timeout_ms: ?u64 = null,
};

pub fn parseFlags(text: []const u8) Flags {
    var out: Flags = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const tail = std.mem.cutPrefix(u8, line, flags_prefix) orelse continue;
        var it = std.mem.tokenizeScalar(u8, tail, ' ');
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "exec-stop")) out.exec_stop = true;
            if (std.mem.eql(u8, tok, "remain")) out.remain = true;
            if (std.mem.eql(u8, tok, "oneshot")) out.oneshot = true;
            if (std.mem.cutPrefix(u8, tok, "start-timeout=")) |ms| out.start_timeout_ms = std.fmt.parseInt(u64, ms, 10) catch null;
        }
        break;
    }
    return out;
}

// ---- s6-svstat -----------------------------------------------------------------------------

/// How the last run of a service ended, as recorded by its `finish` script.
pub const Verdict = runit_native.Verdict;
pub const parseVerdict = runit_native.parseVerdict;

fn firstLine(text: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, text, '\n')) |nl| text[0..nl] else text;
}

fn pidOf(line: []const u8) ?u32 {
    const open = std.mem.find(u8, line, "(pid ") orelse return null;
    const rest = line[open + "(pid ".len ..];
    const end = std.mem.findAny(u8, rest, " )") orelse return null;
    return std.fmt.parseInt(u32, rest[0..end], 10) catch null;
}

/// Signals whose delivery is how a stopped service normally ends.
const clean_signals = [_][]const u8{ "SIGTERM", "SIGHUP", "SIGINT", "SIGPIPE" };

fn endedCleanly(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "down (exitcode ")) {
        const rest = line["down (exitcode ".len..];
        const end = std.mem.findScalar(u8, rest, ')') orelse return false;
        return std.mem.eql(u8, rest[0..end], "0");
    }
    if (std.mem.startsWith(u8, line, "down (signal ")) {
        const rest = line["down (signal ".len..];
        const end = std.mem.findScalar(u8, rest, ')') orelse return false;
        for (clean_signals) |s| if (std.mem.eql(u8, rest[0..end], s)) return true;
        return false;
    }
    return true;
}

/// Normalizes the output of `s6-svstat`. Anything that is not a status line (the service is not
/// supervised, empty output) counts as inactive. `verdict` is the recorded end of the last run
/// and tells a failure from a clean stop; without it the exit status in the line decides.
pub fn parseStatus(text: []const u8, verdict: ?Verdict) interface.Status {
    const line = firstLine(text);
    var state: output.ActiveState = .inactive;
    if (std.mem.startsWith(u8, line, "up (")) {
        state = if (std.mem.find(u8, line, ", want down") != null) .deactivating else .active;
    } else if (std.mem.startsWith(u8, line, "down (")) {
        if (std.mem.find(u8, line, ", want up") != null) {
            state = .activating;
        } else if (verdict) |v| {
            state = if (v == .failed) .failed else .inactive;
        } else if (!std.mem.startsWith(u8, line, "down (not started yet)") and !endedCleanly(line)) {
            state = .failed;
        }
    }
    return .{ .state = state, .pid = pidOf(line), .text = text };
}

/// True when `s6-svstat` printed the status of a service, so an `s6-supervise` runs it.
pub fn hasStatusLine(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "up (") or std.mem.startsWith(u8, text, "down (");
}

/// True when the output of an s6 tool says no `s6-supervise` runs the service yet.
pub fn notSupervised(text: []const u8) bool {
    return std.mem.find(u8, text, "s6-supervise not running") != null or
        std.mem.find(u8, text, "supervisor not listening") != null;
}

/// Non-empty lines of `s6-rc list` or `s6-rc-db list` output.
pub fn nameLines(gpa: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) try out.append(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

pub fn contains(list: []const []const u8, name: []const u8) bool {
    return inList(list, name);
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

test "the command of Artix execline services is the end of the chain" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/sshd", "-D", "-e", "${OPTS}" }, try extractCommand(a,
        \\#!/bin/execlineb -P
        \\foreground { redirfd -w 1 /dev/null ssh-keygen -A }
        \\foreground { touch /var/log/lastlog }
        \\envfile -I /etc/s6/config/openssh.conf
        \\importas -sCuD "" OPTS OPTS
        \\fdmove -c 2 1
        \\exec /usr/bin/sshd -D -e ${OPTS}
        \\
    ));
    try expectWords(&.{ "NetworkManager", "-d" }, try extractCommand(a,
        \\#!/bin/execlineb -P
        \\foreground { mkdir -m0755 -p /etc/NetworkManager/dispatcher.d }
        \\foreground { mkdir -m0700 -p /var/lib/NetworkManager }
        \\fdmove -c 2 1
        \\exec NetworkManager -d
        \\
    ));
    try expectWords(&.{ "dhcpcd", "-B", "-M" }, try extractCommand(a, "#!/bin/execlineb -P\nfdmove -c 2 1\nexec dhcpcd -B -M\n"));
    try expectWords(&.{ "agetty", "-L", "tty1" }, try extractCommand(a,
        \\#!/bin/execlineb -P
        \\if { pipeline { s6-rc -ba list } grep -qFx mount-filesystems }
        \\envfile /etc/s6/config/tty1.conf
        \\importas -uD "yes" SPAWN SPAWN
        \\if -t { test -e /dev/tty1 }
        \\if -t { test ${SPAWN} = "yes" }
        \\exec agetty -L tty1
        \\
    ));
    try expectWords(&.{"/usr/lib/iwd/iwd"}, try extractCommand(a, "#!/bin/execlineb -P\nfdmove -c 2 1\nexec /usr/lib/iwd/iwd\n"));
}

test "wrappers of the chain are walked and the else branch of ifelse wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "s6-log", "-d3", "-b", "--", "${DIRECTIVES}", "/run/log/x" }, try extractCommand(a,
        \\#!/bin/execlineb -P
        \\envfile /etc/s6/config/x.conf
        \\ifelse { test -w /var/log } {
        \\    foreground { install -d -o s6log -g s6log /var/log/x }
        \\    s6-setuidgid s6log exec -c s6-log -d3 -b -- ${DIRECTIVES} /var/log/x
        \\}
        \\foreground { install -d -o s6log -g s6log /run/log/x }
        \\s6-setuidgid s6log exec -c s6-log -d3 -b -- ${DIRECTIVES} /run/log/x
        \\
    ));
    try expectWords(&.{ "/usr/bin/foo", "--bar" }, try extractCommand(a, "export A \"b c\"\numask 027\ncd /srv\ns6-softlimit -H -o 100 /usr/bin/foo --bar\n"));
}

test "quoted words, comments and quoted braces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/printf", "a b", "{", "x\"y" }, try extractExecline(a,
        \\# comment { with a brace
        \\/usr/bin/printf "a b" "{" "x\"y" # trailing
        \\
    ));
    try testing.expect(try extractExecline(a, "foreground { true }\n") == null);
    try testing.expect(try extractExecline(a, "foreground { true\n") == null);
    try testing.expect(try extractExecline(a, "") == null);
    try testing.expect(try extractExecline(a, "# only a comment\n") == null);
}

test "scripts of other interpreters give the last exec line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/bin/foo", "-x" }, try extractCommand(a, "#!/bin/sh\nexec 2>&1\nexec /usr/bin/foo -x\n"));
    try testing.expect(try extractCommand(a, "#!/bin/sh\nsleep 1\n") == null);
}

test "generated flags are read back" {
    const f = parseFlags("#!/bin/sh\n# fake-systemd flags: exec-stop remain\nexec 2>&1\n");
    try testing.expect(f.exec_stop and f.remain);
    try testing.expect(parseFlags("#!/bin/sh\n# fake-systemd flags: oneshot\n").oneshot);
    try testing.expectEqual(@as(?u64, 1500), parseFlags("# fake-systemd flags: oneshot start-timeout=1500\n").start_timeout_ms);
    try testing.expectEqual(@as(?u64, 0), parseFlags("# fake-systemd flags: oneshot start-timeout=0\n").start_timeout_ms);
    const none = parseFlags("#!/bin/sh\nexec 2>&1\n");
    try testing.expect(!none.exec_stop and !none.remain);
}

fn expectStatus(state: output.ActiveState, pid: ?u32, verdict: ?Verdict, text: []const u8) !void {
    const s = parseStatus(text, verdict);
    try testing.expectEqual(state, s.state);
    try testing.expectEqual(pid, s.pid);
}

test "statuses observed from s6-svstat 2.13 and 2.15 map to systemd states" {
    try expectStatus(.active, 57, null, "up (pid 57 pgid 57) 1 seconds\n");
    try expectStatus(.active, 138, null, "up (pid 138 pgid 138) 0 seconds, ready 0 seconds\n");
    try expectStatus(.active, 155, null, "up (pid 155 pgid 155) 1 seconds, normally down\n");
    try expectStatus(.deactivating, 253, null, "up (pid 253 pgid 253) 1 seconds, want down\n");
    try expectStatus(.activating, null, null, "down (exitcode 3) 0 seconds, normally up, want up, ready 0 seconds\n");
    try expectStatus(.activating, null, .failed, "down (exitcode 3) 0 seconds, normally up, want up, ready 0 seconds\n");
    try expectStatus(.inactive, null, null, "down (not started yet) \n");
    try expectStatus(.inactive, null, null, "down (signal SIGTERM) 1 seconds, ready 1 seconds\n");
    try expectStatus(.inactive, null, null, "down (exitcode 0) 5 seconds, normally up, ready 5 seconds\n");
    try expectStatus(.failed, null, null, "down (exitcode 1) 3 seconds, normally up, ready 2 seconds\n");
    try expectStatus(.failed, null, null, "down (signal SIGKILL) 0 seconds, ready 0 seconds\n");
    try expectStatus(.failed, null, null, "down (signal SIGSEGV) 0 seconds, ready 0 seconds\n");
    try expectStatus(.inactive, null, .ok, "down (signal SIGKILL) 0 seconds, ready 0 seconds\n");
    try expectStatus(.failed, null, .failed, "down (exitcode 3) 3 seconds, normally up, ready 3 seconds\n");
    try expectStatus(.inactive, null, null, "s6-svstat: fatal: unable to read status for /run/service/x: s6-supervise not running\n");
    try expectStatus(.inactive, null, null, "");
}

test "a status line means an s6-supervise runs the service" {
    try testing.expect(hasStatusLine("up (pid 1 pgid 1) 2 seconds\n"));
    try testing.expect(hasStatusLine("down (not started yet) \n"));
    try testing.expect(!hasStatusLine("s6-svstat: fatal: unable to read status for x: s6-supervise not running\n"));
    try testing.expect(!hasStatusLine(""));
}

test "unsupervised services are recognised in s6 tool output" {
    try testing.expect(notSupervised("s6-svstat: fatal: unable to read status for /x: s6-supervise not running\n"));
    try testing.expect(notSupervised("s6-svc: warning: unable to control /x: supervisor not listening\n"));
    try testing.expect(notSupervised("s6-svc: fatal: unable to control /x: supervisor not listening\n"));
    try testing.expect(!notSupervised("s6-svc: fatal: timed out\n"));
    try testing.expect(!notSupervised(""));
}

test "list output is split into names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try nameLines(arena.allocator(), "s6rc-fdholder\nfoo-log\n\nfoo-srv\n");
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expect(contains(got, "foo-srv"));
    try testing.expect(!contains(got, "foo"));
}
