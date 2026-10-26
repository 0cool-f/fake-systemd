// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading sysvinit files: the command of an init script, its LSB and chkconfig headers, the
//! names of the `rc?.d` links, and the exit status of the `status` action.
const std = @import("std");
const Allocator = std.mem.Allocator;
const output = @import("../../cli/output.zig");

// ---- command of a script -----------------------------------------------------------------

const Var = struct { name: []const u8, value: []const u8 };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The first value of `name`: a later assignment is usually in a branch that does not apply.
fn lookup(vars: []const Var, name: []const u8) ?[]const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return null;
}

/// Expands `$name`, `${name}`, `${name:-default}` and `${name-default}` from `vars`. Null when a
/// name has no value and no default, or the text uses another form of expansion.
fn expand(gpa: Allocator, text: []const u8, vars: []const Var) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '$') {
            try out.append(gpa, text[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) return null;
        var name: []const u8 = undefined;
        var fallback: ?[]const u8 = null;
        if (text[i] == '{') {
            const close = std.mem.findScalarPos(u8, text, i, '}') orelse return null;
            const inner = text[i + 1 .. close];
            const sep = std.mem.findAny(u8, inner, ":-");
            if (sep) |at| {
                name = inner[0..at];
                const tail = inner[at..];
                fallback = if (std.mem.startsWith(u8, tail, ":-")) tail[2..] else if (tail[0] == '-') tail[1..] else return null;
            } else name = inner;
            i = close + 1;
        } else {
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            name = text[start..i];
        }
        if (name.len == 0) return null;
        for (name) |c| if (!isIdent(c)) return null;
        const value = lookup(vars, name) orelse (fallback orelse return null);
        try out.appendSlice(gpa, value);
    }
    return try out.toOwnedSlice(gpa);
}

const Command = []const []const u8;

/// Splits a logical line into the words of each simple command. Quotes are removed, `;`, `&&`,
/// `||`, `|` and `&` end a command, and a `$(...)` or backquoted part stays in its word.
fn splitCommands(gpa: Allocator, line: []const u8) Allocator.Error![]const Command {
    var commands: std.ArrayList(Command) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: u8 = 0;
    var depth: usize = 0;
    var backquote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else {
                if (c == '\\' and quote == '"' and i + 1 < line.len and std.mem.findScalar(u8, "\"\\$`", line[i + 1]) != null) {
                    i += 1;
                    try word.append(gpa, line[i]);
                    continue;
                }
                try word.append(gpa, c);
            }
            continue;
        }
        if (depth > 0 or backquote) {
            try word.append(gpa, c);
            if (c == '(') depth += 1;
            if (c == ')' and depth > 0) depth -= 1;
            if (c == '`') backquote = false;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                quote = c;
                in_word = true;
            },
            '\\' => {
                in_word = true;
                if (i + 1 < line.len) {
                    i += 1;
                    try word.append(gpa, line[i]);
                }
            },
            '`' => {
                backquote = true;
                in_word = true;
                try word.append(gpa, c);
            },
            '$' => {
                in_word = true;
                try word.append(gpa, c);
                if (i + 1 < line.len and line[i + 1] == '(') {
                    i += 1;
                    depth = 1;
                    try word.append(gpa, '(');
                }
            },
            ' ', '\t' => if (in_word) {
                try words.append(gpa, try word.toOwnedSlice(gpa));
                in_word = false;
            },
            ';', '|', '&' => {
                // `>&2` and `2>&1` are redirections that stay inside their word.
                if (c == '&' and in_word and word.items.len > 0 and (word.items[word.items.len - 1] == '>' or word.items[word.items.len - 1] == '<')) {
                    try word.append(gpa, c);
                    continue;
                }
                if (in_word) {
                    try words.append(gpa, try word.toOwnedSlice(gpa));
                    in_word = false;
                }
                if (i + 1 < line.len and line[i + 1] == c and c != ';') i += 1;
                if (words.items.len > 0) try commands.append(gpa, try words.toOwnedSlice(gpa));
            },
            '#' => if (!in_word) break else {
                try word.append(gpa, c);
            },
            else => {
                in_word = true;
                try word.append(gpa, c);
            },
        }
    }
    if (in_word) try words.append(gpa, try word.toOwnedSlice(gpa));
    if (words.items.len > 0) try commands.append(gpa, try words.toOwnedSlice(gpa));
    return commands.toOwnedSlice(gpa);
}

fn isAssignment(word: []const u8) ?usize {
    var i: usize = 0;
    while (i < word.len and isIdent(word[i])) i += 1;
    return if (i > 0 and i < word.len and word[i] == '=' and !std.ascii.isDigit(word[0])) i else null;
}

const leading_keywords = [_][]const u8{ "if", "then", "else", "elif", "while", "until", "do", "!", "{", "exec", "eval", "time", "command", "export", "readonly", "local", "declare" };

fn isKeyword(word: []const u8) bool {
    for (leading_keywords) |k| if (std.mem.eql(u8, k, word)) return true;
    return false;
}

fn isRedirect(word: []const u8) bool {
    var i: usize = 0;
    while (i < word.len and std.ascii.isDigit(word[i])) i += 1;
    return i < word.len and (word[i] == '<' or word[i] == '>');
}

/// Words of a command without its case-arm label, shell keywords and redirections.
fn trimCommand(words: Command) Command {
    var rest = words;
    while (rest.len > 0) {
        const w = rest[0];
        const arm = w.len > 0 and w[w.len - 1] == ')' and std.mem.findScalar(u8, w, '(') == null;
        if (arm or isKeyword(w) or std.mem.eql(u8, w, ";;")) {
            rest = rest[1..];
        } else break;
    }
    return rest;
}

fn baseName(word: []const u8) []const u8 {
    return std.fs.path.basename(word);
}

fn hasShortFlag(word: []const u8, flag: u8) bool {
    return word.len > 1 and word[0] == '-' and word[1] != '-' and std.mem.findScalar(u8, word[1..], flag) != null;
}

/// `--name value`, `--name=value` or `-n value` at `words[i]`; `i` moves to the last word used.
fn optionValue(words: Command, i: *usize, long: []const u8, short: ?[]const u8) ?[]const u8 {
    const w = words[i.*];
    if (std.mem.eql(u8, w, long) or (short != null and std.mem.eql(u8, w, short.?))) {
        if (i.* + 1 >= words.len) return null;
        i.* += 1;
        return words[i.*];
    }
    if (std.mem.startsWith(u8, w, long) and w.len > long.len and w[long.len] == '=') return w[long.len + 1 ..];
    return null;
}

/// Program and arguments of a `start-stop-daemon --start` command, null for a stop or status
/// command, a `--test` that only probes, or one that names no program.
fn parseSsd(words: Command) ?struct { exe: []const u8, args: Command } {
    var starts = false;
    var probe = false;
    var exe: ?[]const u8 = null;
    var startas: ?[]const u8 = null;
    var args: Command = &.{};
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const w = words[i];
        if (std.mem.eql(u8, w, "--")) {
            args = words[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, w, "--start") or hasShortFlag(w, 'S')) starts = true;
        if (std.mem.eql(u8, w, "--test") or std.mem.eql(u8, w, "-t")) probe = true;
        if (optionValue(words, &i, "--exec", "-x")) |v| exe = v;
        if (optionValue(words, &i, "--startas", "-a")) |v| startas = v;
    }
    if (!starts or probe) return null;
    return .{ .exe = startas orelse exe orelse return null, .args = args };
}

/// Program and arguments of `start_daemon [-f] [-n nice] [-p pidfile] [--] program args`.
fn parseLsbStartDaemon(words: Command) ?struct { exe: []const u8, args: Command } {
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const w = words[i];
        if (std.mem.eql(u8, w, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, w, "-n") or std.mem.eql(u8, w, "-p")) {
            i += 1;
            continue;
        }
        if (w.len > 0 and w[0] == '-') continue;
        break;
    }
    if (i >= words.len) return null;
    return .{ .exe = words[i], .args = words[i + 1 ..] };
}

/// Program and arguments of the `daemon` function of Red Hat's `functions`:
/// `daemon [--check name] [--user name] [--pidfile file] [--force] [+/-nice] program args`.
fn parseRedHatDaemon(words: Command) ?struct { exe: []const u8, args: Command } {
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const w = words[i];
        if (std.mem.eql(u8, w, "--check") or std.mem.eql(u8, w, "--user") or std.mem.eql(u8, w, "--pidfile")) {
            i += 1;
            continue;
        }
        if (w.len > 0 and (w[0] == '-' or w[0] == '+')) continue;
        break;
    }
    if (i >= words.len) return null;
    var end = words.len;
    while (end > i + 1 and isRedirect(words[end - 1])) end -= 1;
    return .{ .exe = words[i], .args = words[i + 1 .. end] };
}

fn isProgramPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    return std.mem.find(u8, path, "bin/") != null or std.mem.find(u8, path, "libexec/") != null;
}

/// Path of a program named `name`: a variable of the script holds it, else the script mentions
/// it, as `[ -x /usr/sbin/name ]` does.
fn pathNamed(gpa: Allocator, vars: []const Var, content: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    for (vars) |v| {
        if (isProgramPath(v.value) and std.mem.eql(u8, baseName(v.value), name)) return v.value;
    }
    var it = std.mem.tokenizeAny(u8, content, " \t\r\n;|&()[]{}\"'=`<>");
    while (it.next()) |tok| {
        if (isProgramPath(tok) and std.mem.eql(u8, baseName(tok), name)) return try gpa.dupe(u8, tok);
    }
    return null;
}

/// Program of `killproc [-p pidfile] [-b binary] [-d delay] program [-signal]`.
fn parseKillproc(words: Command) ?[]const u8 {
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const w = words[i];
        if (std.mem.eql(u8, w, "-p") or std.mem.eql(u8, w, "-b") or std.mem.eql(u8, w, "-d")) {
            i += 1;
            continue;
        }
        return if (w.len > 0 and w[0] != '-') w else null;
    }
    return null;
}

const Candidate = struct {
    exe: []const u8,
    args: Command,
    /// The command starts the program; otherwise it only names it, as `killproc` does.
    starts: bool = true,
};

fn candidateOf(words: Command) ?Candidate {
    if (words.len == 0) return null;
    const name = baseName(words[0]);
    if (std.mem.eql(u8, name, "start-stop-daemon")) {
        const p = parseSsd(words[1..]) orelse return null;
        return .{ .exe = p.exe, .args = p.args };
    }
    if (std.mem.eql(u8, name, "start_daemon")) {
        const p = parseLsbStartDaemon(words[1..]) orelse return null;
        return .{ .exe = p.exe, .args = p.args };
    }
    if (std.mem.eql(u8, name, "daemon")) {
        const p = parseRedHatDaemon(words[1..]) orelse return null;
        return .{ .exe = p.exe, .args = p.args };
    }
    if (std.mem.eql(u8, name, "killproc")) {
        const exe = parseKillproc(words[1..]) orelse return null;
        return .{ .exe = exe, .args = &.{}, .starts = false };
    }
    return null;
}

/// Reads logical lines: a backslash at the end of a line joins it with the next.
const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    fn next(l: *Lines, gpa: Allocator) Allocator.Error!?[]const u8 {
        if (l.pos >= l.text.len) return null;
        var out: std.ArrayList(u8) = .empty;
        while (l.pos < l.text.len) {
            const end = std.mem.findScalarPos(u8, l.text, l.pos, '\n') orelse l.text.len;
            const raw = std.mem.trimEnd(u8, l.text[l.pos..end], "\r");
            l.pos = @min(end + 1, l.text.len);
            if (std.mem.endsWith(u8, raw, "\\")) {
                try out.appendSlice(gpa, raw[0 .. raw.len - 1]);
                try out.append(gpa, ' ');
                continue;
            }
            try out.appendSlice(gpa, raw);
            break;
        }
        return try out.toOwnedSlice(gpa);
    }
};

/// Command words of an init script: the program of the first `start-stop-daemon --start`,
/// `start_daemon` or `daemon` command, with the variables the script assigned before expanded.
/// A script that only stops its program with `killproc`, or runs `$DAEMON` itself or through
/// `init-d-script`, gives that program. Null when the program stays unknown, as when it comes
/// from a file the script sources.
pub fn extractCommand(gpa: Allocator, content: []const u8) Allocator.Error!?[]const []const u8 {
    var vars: std.ArrayList(Var) = .empty;
    var named: ?[]const []const u8 = null;
    var lines: Lines = .{ .text = content };
    while (try lines.next(gpa)) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        for (try splitCommands(gpa, line)) |all| {
            const words = trimCommand(all);
            if (words.len == 0) continue;
            if (isAssignment(words[0]) != null) {
                var only = true;
                for (words) |w| if (isAssignment(w) == null) {
                    only = false;
                    break;
                };
                if (only) {
                    for (words) |w| {
                        const eq = isAssignment(w).?;
                        const value = (try expand(gpa, w[eq + 1 ..], vars.items)) orelse continue;
                        try vars.append(gpa, .{ .name = w[0..eq], .value = value });
                    }
                    continue;
                }
            }
            var start: usize = 0;
            while (start < words.len and isAssignment(words[start]) != null) start += 1;
            const cand = candidateOf(words[start..]) orelse continue;
            const exe = (try expand(gpa, cand.exe, vars.items)) orelse continue;
            if (exe.len == 0 or std.mem.findScalar(u8, exe, '$') != null) continue;
            var out: std.ArrayList([]const u8) = .empty;
            const resolved = if (std.mem.findScalar(u8, exe, '/') == null) ((try pathNamed(gpa, vars.items, content, exe)) orelse exe) else exe;
            try out.append(gpa, resolved);
            for (cand.args) |a| try out.append(gpa, (try expand(gpa, a, vars.items)) orelse a);
            if (cand.starts) return try out.toOwnedSlice(gpa);
            if (named == null) named = try out.toOwnedSlice(gpa);
        }
    }
    if (named) |n| return n;
    if (lookup(vars.items, "DAEMON")) |daemon| {
        if (daemon.len > 0 and daemon[0] == '/') return try gpa.dupe([]const u8, &.{daemon});
    }
    return null;
}

// ---- headers -----------------------------------------------------------------------------

/// What `update-rc.d` and `chkconfig` read from the header of a script.
pub const Header = struct {
    provides: []const []const u8 = &.{},
    required_start: []const []const u8 = &.{},
    should_start: []const []const u8 = &.{},
    /// Scripts a generated script requires and `enable` enables with it (`# Pulls-In:`).
    pulls_in: []const []const u8 = &.{},
    /// Runlevels of `Default-Start:`, one character each; `chkconfig:` levels when the LSB header has none.
    default_start: []const u8 = "",
    default_stop: []const u8 = "",
    /// `chkconfig:` priorities, when the script has that line.
    start_priority: ?u8 = null,
    stop_priority: ?u8 = null,
    /// The script has an LSB block, or a `chkconfig:` line.
    has_lsb: bool = false,
    has_chkconfig: bool = false,
};

fn splitFields(gpa: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t");
    while (it.next()) |w| try out.append(gpa, w);
    return out.toOwnedSlice(gpa);
}

/// Runlevel characters of a `Default-Start:` value: `2 3 4 5` and the Red Hat spelling `2345`.
fn levelsOf(gpa: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (c == ' ' or c == '\t') continue;
        // Some scripts put priorities in the field, which names no runlevel.
        if (std.mem.findScalar(u8, "0123456S", c) == null) return "";
        if (std.mem.findScalar(u8, out.items, c) == null) try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

fn priority(text: []const u8) ?u8 {
    const n = std.fmt.parseInt(u8, text, 10) catch return null;
    return if (n <= 99) n else null;
}

pub fn parseHeader(gpa: Allocator, content: []const u8) Allocator.Error!Header {
    var h: Header = .{};
    var in_lsb = false;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var lsb_start: ?[]const u8 = null;
    var lsb_stop: ?[]const u8 = null;
    var chk_levels: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "### BEGIN INIT INFO")) {
            in_lsb = true;
            h.has_lsb = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "### END INIT INFO")) {
            in_lsb = false;
            continue;
        }
        if (line.len == 0 or line[0] != '#') {
            if (line.len > 0 and !in_lsb and (h.has_chkconfig or h.has_lsb)) break;
            continue;
        }
        const body = std.mem.trim(u8, line[1..], " \t");
        const colon = std.mem.findScalar(u8, body, ':') orelse continue;
        const key = body[0..colon];
        const value = std.mem.trim(u8, body[colon + 1 ..], " \t");
        if (in_lsb) {
            if (std.ascii.eqlIgnoreCase(key, "Provides")) h.provides = try splitFields(gpa, value);
            if (std.ascii.eqlIgnoreCase(key, "Required-Start")) h.required_start = try splitFields(gpa, value);
            if (std.ascii.eqlIgnoreCase(key, "Should-Start")) h.should_start = try splitFields(gpa, value);
            if (std.ascii.eqlIgnoreCase(key, "Default-Start")) lsb_start = try levelsOf(gpa, value);
            if (std.ascii.eqlIgnoreCase(key, "Default-Stop")) lsb_stop = try levelsOf(gpa, value);
        } else if (std.mem.eql(u8, key, "Pulls-In")) {
            h.pulls_in = try splitFields(gpa, value);
        } else if (std.mem.eql(u8, key, "chkconfig") and !h.has_chkconfig) {
            var it = std.mem.tokenizeAny(u8, value, " \t");
            const levels = it.next() orelse continue;
            const start = priority(it.next() orelse continue) orelse continue;
            const stop = priority(it.next() orelse continue) orelse continue;
            h.has_chkconfig = true;
            chk_levels = if (std.mem.eql(u8, levels, "-")) "" else try levelsOf(gpa, levels);
            h.start_priority = start;
            h.stop_priority = stop;
        }
    }
    h.default_start = lsb_start orelse chk_levels orelse "";
    h.default_stop = lsb_stop orelse "";
    return h;
}

// ---- links -------------------------------------------------------------------------------

/// A name in an `rc?.d` directory: `S`, or `K`, two digits and the name of the script.
pub const Link = struct {
    start: bool,
    number: u8,
    name: []const u8,
};

pub fn parseLink(file: []const u8) ?Link {
    if (file.len < 4 or (file[0] != 'S' and file[0] != 'K')) return null;
    const number = std.fmt.parseInt(u8, file[1..3], 10) catch return null;
    return .{ .start = file[0] == 'S', .number = number, .name = file[3..] };
}

/// Default runlevel from an `initdefault` entry of `inittab`.
pub fn parseInitDefault(content: []const u8) ?u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, trimmed, ':');
        _ = fields.next() orelse continue;
        const level = fields.next() orelse continue;
        const action = fields.next() orelse continue;
        if (!std.mem.eql(u8, action, "initdefault") or level.len != 1) continue;
        if (level[0] >= '1' and level[0] <= '5') return level[0];
    }
    return null;
}

// ---- status ------------------------------------------------------------------------------

/// Exit statuses of the `status` action (LSB 5.0, "Init Script Actions").
pub const status_dead_pid_file = 1;
pub const status_dead_lock_file = 2;
pub const status_not_running = 3;

/// Normalized state from the exit status of `status`. A script that does not know the action
/// prints its usage and exits 1 or 2; that is no failure of the service.
pub fn stateOfStatus(code: u8, usage_text: bool) output.ActiveState {
    if (usage_text) return .inactive;
    return switch (code) {
        0 => .active,
        status_dead_pid_file, status_dead_lock_file => .failed,
        else => .inactive,
    };
}

pub fn looksLikeUsage(text: []const u8) bool {
    return std.ascii.findIgnoreCase(text, "usage:") != null;
}

/// Process id in a pid file.
pub fn parsePid(text: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const pid = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    return if (pid == 0) null else pid;
}

const testing = std.testing;

fn expectWords(expected: []const []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqual(expected.len, g.len);
    for (expected, g) |e, w| try testing.expectEqualStrings(e, w);
}

fn expectExe(expected: []const u8, got: ?[]const []const u8) !void {
    const g = got orelse return error.TestExpectedWords;
    try testing.expectEqualStrings(expected, g[0]);
}

test "start-stop-daemon commands give the program and its arguments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/chronyd", "-x" }, try extractCommand(a,
        \\NAME="chronyd"
        \\DAEMON=/usr/sbin/$NAME
        \\DAEMON_OPTS="-x"
        \\do_start() {
        \\    start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON -- $DAEMON_OPTS
        \\}
        \\
    ));
    try expectWords(&.{ "/usr/sbin/ntpd", "-p", "/run/ntp.pid" }, try extractCommand(a,
        \\DAEMON=/usr/sbin/ntpd
        \\case "$1" in
        \\  start)  start-stop-daemon --start --quiet --oknodo --pidfile /run/ntp.pid --startas $DAEMON -- -p /run/ntp.pid ;;
        \\  stop)   start-stop-daemon --stop --pidfile /run/ntp.pid ;;
        \\esac
        \\
    ));
}

test "continuation lines, conditions and the stop command that comes first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/named", "-u", "bind" }, try extractCommand(a,
        \\stop() {
        \\    start-stop-daemon --stop --oknodo --quiet --exec /usr/sbin/named
        \\}
        \\start() {
        \\    if start-stop-daemon --start --oknodo --quiet --exec /usr/sbin/named \
        \\        --pidfile /run/named.pid -- -u bind; then
        \\        :
        \\    fi
        \\}
        \\
    ));
    try expectWords(&.{ "/usr/sbin/haveged", "-w", "1024" }, try extractCommand(a,
        \\DAEMON=/usr/sbin/haveged
        \\start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON --test > /dev/null \
        \\  || return 1
        \\start-stop-daemon --start --quiet --pidfile $PIDFILE --exec $DAEMON -- -w 1024
        \\
    ));
}

test "start_daemon of the LSB functions and init-d-script" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/cron", "-l" }, try extractCommand(a, "DAEMON=/usr/sbin/cron\nstart_daemon -p $PIDFILE $DAEMON -l\n"));
    try expectWords(&.{"/usr/sbin/atd"}, try extractCommand(a, "DAEMON=/usr/sbin/atd\n\tstart_daemon -f -n 5 -p /run/atd.pid -- $DAEMON\n"));
    try expectWords(&.{"/usr/bin/htcacheclean"}, try extractCommand(a, "#!/bin/sh\n### BEGIN INIT INFO\n### END INIT INFO\nDAEMON=/usr/bin/htcacheclean\n. /lib/init/init-d-script\n"));
}

test "the daemon function of Red Hat takes options before the program" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectExe("/usr/sbin/httpd", try extractCommand(a,
        \\httpd=${HTTPD-/usr/sbin/httpd}
        \\pidfile=${PIDFILE-/var/run/httpd/httpd.pid}
        \\OPTIONS="-k start"
        \\start() {
        \\    LANG=$HTTPD_LANG daemon --pidfile=${pidfile} $httpd $OPTIONS
        \\}
        \\
    ));
    try expectExe("/sbin/rsyslogd", try extractCommand(a,
        \\PIDFILE=/var/run/syslogd.pid
        \\exec=/sbin/rsyslogd
        \\start() {
        \\        daemon --pidfile="$PIDFILE" $exec -i "$PIDFILE" $SYSLOGD_OPTIONS
        \\}
        \\
    ));
    try expectExe("/usr/sbin/named", try extractCommand(a,
        \\named='named'
        \\    daemon --pidfile "$ROOTDIR$PIDFILE" /usr/sbin/"$named" -u named ${OPTIONS};
        \\
    ));
    try expectWords(&.{ "/usr/sbin/sendmail", "-bd" }, try extractCommand(a, "daemon /usr/sbin/sendmail -bd 2>/dev/null\n"));
}

test "a program name is completed from a variable holding its path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{ "/usr/sbin/crond", "-n" }, try extractCommand(a,
        \\prog="crond"
        \\exec=/usr/sbin/crond
        \\start() {
        \\    daemon $prog -n
        \\}
        \\
    ));
}

test "a program that stays unknown gives no command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try extractCommand(a, "start-stop-daemon --start --exec $DAEMON\n") == null);
    try testing.expect(try extractCommand(a, "# start-stop-daemon --start --exec /usr/sbin/foo\n") == null);
    try testing.expect(try extractCommand(a, "echo \"daemon start-stop-daemon\"\nstart-stop-daemon --stop --exec /usr/sbin/foo\n") == null);
    try testing.expect(try extractCommand(a, "") == null);
    try testing.expect(try extractCommand(a, "DAEMON=$(which foo)\nstart-stop-daemon --start --exec $DAEMON\n") == null);
}

test "headers give dependencies, runlevels and priorities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try parseHeader(a,
        \\#!/bin/sh
        \\# chkconfig: 35 55 45
        \\# description: foo \
        \\#              more
        \\### BEGIN INIT INFO
        \\# Provides:          foo bar
        \\# Required-Start:    $remote_fs dep
        \\# Should-Start:      $network
        \\# Default-Start:     2 3 4 5
        \\# Default-Stop:      0 1 6
        \\# Short-Description: foo
        \\### END INIT INFO
        \\echo not a header # Provides: other
        \\
    );
    try testing.expectEqual(@as(usize, 2), h.provides.len);
    try testing.expectEqualStrings("dep", h.required_start[1]);
    try testing.expectEqualStrings("$network", h.should_start[0]);
    try testing.expectEqualStrings("2345", h.default_start);
    try testing.expectEqualStrings("016", h.default_stop);
    try testing.expectEqual(@as(?u8, 55), h.start_priority);
    try testing.expectEqual(@as(?u8, 45), h.stop_priority);
    try testing.expect(h.has_lsb and h.has_chkconfig);

    const only = try parseHeader(a, "#!/bin/sh\n# chkconfig: 2345 90 60\n# description: x\n\nexit 0\n");
    try testing.expectEqualStrings("2345", only.default_start);
    try testing.expectEqual(@as(?u8, 90), only.start_priority);
    try testing.expect(!only.has_lsb);
    const off = try parseHeader(a, "#!/bin/sh\n# chkconfig: - 58 74\n");
    try testing.expectEqualStrings("", off.default_start);
    const red_hat = try parseHeader(a, "### BEGIN INIT INFO\n# Default-Start:  2345\n# Default-Stop: 90\n### END INIT INFO\n");
    try testing.expectEqualStrings("2345", red_hat.default_start);
    try testing.expectEqualStrings("", red_hat.default_stop);
    const bare = try parseHeader(a, "#!/bin/sh\nexit 0\n");
    try testing.expect(!bare.has_lsb and !bare.has_chkconfig);
}

test "link names and the default runlevel" {
    const s = parseLink("S20foo").?;
    try testing.expect(s.start and s.number == 20 and std.mem.eql(u8, s.name, "foo"));
    try testing.expect(!parseLink("K01foo.bar").?.start);
    try testing.expect(parseLink("README") == null);
    try testing.expect(parseLink("S2foo") == null);
    try testing.expect(parseLink("Sxxfoo") == null);
    try testing.expectEqual(@as(?u8, '3'), parseInitDefault("# c\nid:3:initdefault:\n"));
    try testing.expectEqual(@as(?u8, null), parseInitDefault("# inittab is no longer used.\n# id:5:initdefault:\n"));
    try testing.expectEqual(@as(?u8, null), parseInitDefault("id:6:initdefault:\n"));
}

test "status codes map to states and a usage text is no failure" {
    try testing.expectEqual(output.ActiveState.active, stateOfStatus(0, false));
    try testing.expectEqual(output.ActiveState.failed, stateOfStatus(1, false));
    try testing.expectEqual(output.ActiveState.failed, stateOfStatus(2, false));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(3, false));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(4, false));
    try testing.expectEqual(output.ActiveState.inactive, stateOfStatus(1, true));
    try testing.expect(looksLikeUsage("Usage: /etc/init.d/foo {start|stop}"));
    try testing.expect(!looksLikeUsage("foo is dead"));
    try testing.expectEqual(@as(?u32, 77), parsePid("77\n"));
    try testing.expectEqual(@as(?u32, null), parsePid("0"));
}

test "a script that only stops its program, or runs it itself, still names it, and a start wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectExe("/usr/sbin/sshd", try extractCommand(a, "SSHD=/usr/sbin/sshd\nstop() {\n\tkillproc -p $PID_FILE $SSHD\n}\n"));
    try expectExe("/usr/sbin/avahi-daemon", try extractCommand(a, "NAME=\"avahi-daemon\"\nDAEMON=\"/usr/sbin/$NAME\"\nstart() {\n\t$DAEMON -D\n}\n"));
    try expectExe("/usr/sbin/a", try extractCommand(a, "killproc /usr/sbin/b\nstart-stop-daemon --start --exec /usr/sbin/a\n"));
    try testing.expect(try extractCommand(a, "killproc -p /run/x.pid\n") == null);
}

test "the first value of a variable counts, a probe is no start, and a program is found where the script names it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectWords(&.{"/usr/sbin/named"}, try extractCommand(a, "named='named'\nif sdb; then named=named-sdb; fi\ndaemon /usr/sbin/\"$named\"\n"));
    try expectWords(&.{"/usr/sbin/b"}, try extractCommand(a, "start-stop-daemon --start --test --exec /usr/sbin/a\nstart-stop-daemon --start --exec /usr/sbin/b\n"));
    try expectWords(&.{ "/usr/sbin/ntpd", "$OPTIONS" }, try extractCommand(a, "prog=ntpd\nstart() {\n\t[ -x /usr/sbin/ntpd ] || exit 5\n\tdaemon $prog $OPTIONS\n}\n"));
    try expectWords(&.{"rpcbind"}, try extractCommand(a, "prog=rpcbind\ndaemon $prog\n"));
}
