// SPDX-License-Identifier: GPL-3.0-or-later
//! Filesystem access rooted at a directory handle. Every method takes an absolute path
//! that is resolved relative to the root. Operations that follow symlinks (`stat`, `exists`,
//! `readFileAlloc`, `iterateDir`, `devIno`) resolve them inside the root, so an absolute link
//! never escapes it; `lstat` and `readLink` never follow.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const linux = std.os.linux;

const Fs = @This();

pub const Kind = File.Kind;

pub const Stat = struct {
    kind: Kind,
    size: u64,
    inode: u64,
    mtime_ns: i96,
    /// Permission bits only (`& 0o7777`).
    mode: u16,
    uid: u32 = 0,
    gid: u32 = 0,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

pub const DevIno = struct {
    dev_major: u32,
    dev_minor: u32,
    ino: u64,

    pub fn eql(a: DevIno, b: DevIno) bool {
        return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
    }
};

pub const max_symlink_hops = 40;

io: Io,
root: Dir,
owns_root: bool,
/// True when the root is the host `/`, where the OS resolves symlinks itself.
host_root: bool = false,

/// Opens `abs_root_path` as the root; release with `deinit`.
pub fn initRoot(io: Io, abs_root_path: []const u8) !Fs {
    const root = try Dir.openDirAbsolute(io, abs_root_path, .{ .iterate = true });
    return .{ .io = io, .root = root, .owns_root = true, .host_root = std.mem.eql(u8, abs_root_path, "/") };
}

/// Uses an already open directory as the root; the caller keeps ownership of `dir`.
pub fn initDir(io: Io, dir: Dir) Fs {
    return .{ .io = io, .root = dir, .owns_root = false };
}

pub fn deinit(fs: *Fs) void {
    if (fs.owns_root) fs.root.close(fs.io);
    fs.* = undefined;
}

fn rel(abs: []const u8) []const u8 {
    std.debug.assert(abs.len > 0 and abs[0] == '/');
    const trimmed = std.mem.trimStart(u8, abs, "/");
    return if (trimmed.len == 0) "." else trimmed;
}

fn kindOfMode(mode: u16) Kind {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFREG => .file,
        linux.S.IFDIR => .directory,
        linux.S.IFLNK => .sym_link,
        linux.S.IFIFO => .named_pipe,
        linux.S.IFSOCK => .unix_domain_socket,
        linux.S.IFCHR => .character_device,
        linux.S.IFBLK => .block_device,
        else => .unknown,
    };
}

/// Status of the in-root path `abs`; a symlink at the last component is followed with `follow_link`.
fn statRaw(fs: Fs, abs: []const u8, follow_link: bool) !Stat {
    const sub = rel(abs);
    var z: [path_cap:0]u8 = undefined;
    if (sub.len >= path_cap) return error.NameTooLong;
    @memcpy(z[0..sub.len], sub);
    z[sub.len] = 0;
    var stx: linux.Statx = undefined;
    const flags: u32 = if (follow_link) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(fs.root.handle, z[0..sub.len :0], flags, .{
        .TYPE = true,
        .MODE = true,
        .UID = true,
        .GID = true,
        .INO = true,
        .SIZE = true,
        .MTIME = true,
    }, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
    return .{
        .kind = kindOfMode(stx.mode),
        .size = stx.size,
        .inode = stx.ino,
        .mtime_ns = @as(i96, stx.mtime.sec) * std.time.ns_per_s + stx.mtime.nsec,
        .mode = stx.mode & 0o7777,
        .uid = stx.uid,
        .gid = stx.gid,
    };
}

pub fn readFileAlloc(fs: Fs, gpa: std.mem.Allocator, abs: []const u8, max_size: usize) ![]u8 {
    var buf: [path_cap]u8 = undefined;
    return fs.root.readFileAlloc(fs.io, rel(try fs.follow(&buf, abs)), gpa, .limited(max_size));
}

pub fn stat(fs: Fs, abs: []const u8) !Stat {
    var buf: [path_cap]u8 = undefined;
    return fs.statRaw(try fs.follow(&buf, abs), true);
}

pub fn lstat(fs: Fs, abs: []const u8) !Stat {
    var buf: [path_cap]u8 = undefined;
    return fs.lstatRaw(try fs.followParent(&buf, abs));
}

fn lstatRaw(fs: Fs, abs: []const u8) !Stat {
    return fs.statRaw(abs, false);
}

/// True when the path resolves inside the root; any other failure reads as absent.
pub fn exists(fs: Fs, abs: []const u8) bool {
    var buf: [path_cap]u8 = undefined;
    const target = fs.follow(&buf, abs) catch return false;
    fs.root.access(fs.io, rel(target), .{}) catch return false;
    return true;
}

pub fn readLink(fs: Fs, abs: []const u8, buf: []u8) ![]u8 {
    var path: [path_cap]u8 = undefined;
    return fs.readLinkRaw(try fs.followParent(&path, abs), buf);
}

fn readLinkRaw(fs: Fs, abs: []const u8, buf: []u8) ![]u8 {
    const n = try fs.root.readLink(fs.io, rel(abs), buf);
    return buf[0..n];
}

/// Returns entries sorted by name; free with `freeEntries`.
/// Kind of directory entry `e`: filesystems that do not report a type in the listing are asked.
fn entryKind(fs: Fs, dir: Dir, e: Dir.Entry) Kind {
    if (e.kind != .unknown) return e.kind;
    const st = dir.statFile(fs.io, e.name, .{ .follow_symlinks = false }) catch return .unknown;
    return st.kind;
}

pub fn iterateDir(fs: Fs, gpa: std.mem.Allocator, abs: []const u8) ![]Entry {
    var buf: [path_cap]u8 = undefined;
    var dir = try fs.root.openDir(fs.io, rel(try fs.follow(&buf, abs)), .{ .iterate = true });
    defer dir.close(fs.io);
    var list: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(gpa, list.toOwnedSlice(gpa) catch &.{});
    var it = dir.iterate();
    while (try it.next(fs.io)) |e| {
        const name = try gpa.dupe(u8, e.name);
        errdefer gpa.free(name);
        try list.append(gpa, .{ .name = name, .kind = fs.entryKind(dir, e) });
    }
    std.mem.sort(Entry, list.items, {}, entryLessThan);
    return list.toOwnedSlice(gpa);
}

fn entryLessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| gpa.free(e.name);
    gpa.free(entries);
}

/// Creates `abs` and its missing parents with mode 0755. Existing components that are symlinks
/// are resolved inside the root.
pub fn makePath(fs: Fs, abs: []const u8) !void {
    return fs.makePathMode(abs, 0o755);
}

/// `makePath` with `mode` (before the umask) for every directory it creates.
pub fn makePathMode(fs: Fs, abs: []const u8, mode: u16) !void {
    const permissions: Io.File.Permissions = .fromMode(mode);
    if (fs.host_root) {
        // `/etc/init.d` is a link to `rc.d/init.d` on Red Hat; the creation refuses a link.
        if (fs.root.statFile(fs.io, rel(abs), .{})) |st| {
            if (st.kind == .directory) return;
        } else |_| {}
        _ = try fs.root.createDirPathStatus(fs.io, rel(abs), permissions);
        return;
    }
    var cur: [path_cap]u8 = undefined;
    var cur_len: usize = 0;
    var cand_buf: [path_cap]u8 = undefined;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            cur_len = std.mem.findScalarLast(u8, cur[0..cur_len], '/') orelse 0;
            continue;
        }
        const cand = try std.fmt.bufPrint(&cand_buf, "{s}/{s}", .{ cur[0..cur_len], comp });
        const kind: Kind = if (fs.lstatRaw(cand)) |st| st.kind else |e| switch (e) {
            error.FileNotFound => blk: {
                // A concurrent creator of the same path wins the race; its directory is used.
                fs.root.createDir(fs.io, rel(cand), permissions) catch |ce| switch (ce) {
                    error.PathAlreadyExists => {},
                    else => return ce,
                };
                break :blk (try fs.lstatRaw(cand)).kind;
            },
            else => return e,
        };
        switch (kind) {
            .directory => {
                @memcpy(cur[0..cand.len], cand);
                cur_len = cand.len;
            },
            .sym_link => {
                var real_buf: [path_cap]u8 = undefined;
                const real = try fs.resolveInto(&real_buf, cand);
                if ((try fs.lstatRaw(real)).kind != .directory) return error.NotDir;
                cur_len = if (real.len == 1) 0 else real.len;
                @memcpy(cur[0..cur_len], real[0..cur_len]);
            },
            else => return error.NotDir,
        }
    }
}

/// Path whose parent directory is resolved inside the root; the final component is kept as is.
fn followParent(fs: Fs, out: *[path_cap]u8, abs: []const u8) ![]const u8 {
    if (fs.host_root) return abs;
    const base = std.fs.path.basename(abs);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return fs.resolveInto(out, abs);
    }
    const dir = std.fs.path.dirname(abs) orelse "/";
    var dir_buf: [path_cap]u8 = undefined;
    const real_dir = try fs.resolveInto(&dir_buf, dir);
    return std.fmt.bufPrint(out, "{s}/{s}", .{ if (real_dir.len == 1) "" else real_dir, base }) catch error.NameTooLong;
}

pub fn deleteFile(fs: Fs, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    try fs.root.deleteFile(fs.io, rel(try fs.followParent(&buf, abs)));
}

/// Removes `abs` and everything below it; a symlink at `abs` is removed itself.
pub fn deleteTree(fs: Fs, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    try fs.root.deleteTree(fs.io, rel(try fs.followParent(&buf, abs)));
}

pub fn rename(fs: Fs, src_abs: []const u8, dst_abs: []const u8) !void {
    var src: [path_cap]u8 = undefined;
    var dst: [path_cap]u8 = undefined;
    try fs.root.rename(rel(try fs.followParent(&src, src_abs)), fs.root, rel(try fs.followParent(&dst, dst_abs)), fs.io);
}

/// Creates `abs` as a symlink whose content is `target` verbatim.
pub fn symLink(fs: Fs, target: []const u8, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    try fs.root.symLink(fs.io, target, rel(try fs.followParent(&buf, abs)), .{});
}

/// Writes `content` to a sibling temporary file, syncs it, renames it over `abs` and syncs
/// the directory. Fails with `DestinationIsSymlink` when `abs` is a symlink. As root the new file
/// gets the owner of the one it replaces. Temporary files
/// that an earlier interrupted write left for the same target are removed first.
pub fn writeFileAtomic(fs: Fs, abs: []const u8, content: []const u8, mode: u16) !void {
    var real_buf: [path_cap]u8 = undefined;
    const real = try fs.followParent(&real_buf, abs);
    const existing = try fs.destinationStat(real);
    fs.removeStaleTemps(real);
    var tmp_buf: [Dir.max_path_bytes]u8 = undefined;
    const tmp_abs = try fs.tempSibling(&tmp_buf, real);
    {
        const file = try fs.root.createFile(fs.io, rel(tmp_abs), .{
            .exclusive = true,
            .permissions = .fromMode(mode),
        });
        defer file.close(fs.io);
        errdefer fs.deleteFile(tmp_abs) catch {};
        // Root keeps the owner of the file it replaces; the owner is set before the mode, which
        // a change of owner can reset.
        if (existing) |st| {
            if (linux.geteuid() == 0 and (st.uid != 0 or st.gid != 0)) try file.setOwner(fs.io, st.uid, st.gid);
        }
        try file.setPermissions(fs.io, .fromMode(mode));
        try file.writeStreamingAll(fs.io, content);
        try file.sync(fs.io);
    }
    errdefer fs.deleteFile(tmp_abs) catch {};
    try fs.rename(tmp_abs, real);
    try fs.syncDir(std.fs.path.dirname(real) orelse "/");
}

pub const Access = enum { read, write, read_write };

pub const OpenOptions = struct {
    access: Access = .read,
    /// Mode of the file when it is created; null opens an existing file only.
    create: ?u16 = null,
    /// With `create`: fail with `PathAlreadyExists` when the file exists.
    exclusive: bool = false,
};

/// Opens `abs` without following a symlink at the last component (`SymLinkLoop`), without
/// blocking on a FIFO, and inside the root: the parent directories are resolved like every
/// other operation.
pub fn openNoFollow(fs: Fs, abs: []const u8, opts: OpenOptions) !File {
    var real_buf: [path_cap]u8 = undefined;
    const real = try fs.followParent(&real_buf, abs);
    const sub = rel(real);
    var z: [path_cap:0]u8 = undefined;
    if (sub.len >= path_cap) return error.NameTooLong;
    @memcpy(z[0..sub.len], sub);
    z[sub.len] = 0;
    const rc = linux.openat(fs.root.handle, z[0..sub.len :0], .{
        .ACCMODE = switch (opts.access) {
            .read => .RDONLY,
            .write => .WRONLY,
            .read_write => .RDWR,
        },
        .CREAT = opts.create != null,
        .EXCL = opts.exclusive,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, opts.create orelse 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .handle = @intCast(rc), .flags = .{ .nonblocking = false } },
        else => |e| errnoError(e),
    };
}

pub const FileInfo = struct {
    uid: u32,
    gid: u32,
    /// Permission bits only (`& 0o7777`).
    mode: u16,
    nlink: u32,
    kind: Kind,
};

/// Owner, mode, link count and type of an open file.
pub fn fileInfo(file: File) !FileInfo {
    var stx: linux.Statx = undefined;
    const rc = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true }, &stx);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| return errnoError(e),
    }
    return .{
        .uid = stx.uid,
        .gid = stx.gid,
        .mode = stx.mode & 0o7777,
        .nlink = stx.nlink,
        .kind = kindOfMode(stx.mode),
    };
}

/// Owner, mode and type of the directory `abs`, resolved inside the root.
pub fn dirInfo(fs: Fs, abs: []const u8) !FileInfo {
    var buf: [path_cap]u8 = undefined;
    var dir = try fs.root.openDir(fs.io, rel(try fs.follow(&buf, abs)), .{});
    defer dir.close(fs.io);
    return fileInfo(.{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
}

fn errnoError(e: linux.E) anyerror {
    return switch (e) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .LOOP => error.SymLinkLoop,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .ROFS => error.ReadOnlyFileSystem,
        .NOSPC => error.NoSpaceLeft,
        .NAMETOOLONG => error.NameTooLong,
        .DQUOT => error.DiskQuota,
        .IO => error.InputOutput,
        .NXIO => error.NoDevice,
        else => error.Unexpected,
    };
}

/// Truncates and writes the regular file `abs` in place, creating it with `mode` when it is
/// missing. A symlink or a non-regular file at `abs` is refused. A file the running user does
/// not own, or that has other links, is replaced by a new file when running as root, so that
/// content and permissions are always the writer's. Unlike `writeFileAtomic` it needs no write
/// permission on the directory when the file exists and is writable.
pub fn writeFileInPlace(fs: Fs, abs: []const u8, content: []const u8, mode: u16) !void {
    const euid = linux.geteuid();
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        const file = fs.openNoFollow(abs, .{ .access = .write }) catch |e| switch (e) {
            error.FileNotFound => {
                if (try fs.createInPlace(abs, content, mode)) return;
                continue;
            },
            error.SymLinkLoop => return error.DestinationIsSymlink,
            else => return e,
        };
        defer file.close(fs.io);
        const info = try fileInfo(file);
        if (info.kind != .file) return error.NotRegularFile;
        if (euid == 0 and (info.uid != 0 or info.nlink > 1)) {
            try fs.deleteFile(abs);
            continue;
        }
        switch (linux.errno(linux.ftruncate(file.handle, 0))) {
            .SUCCESS => {},
            else => |e| return errnoError(e),
        }
        try file.writeStreamingAll(fs.io, content);
        if (info.uid == euid and info.mode != mode) try file.setPermissions(fs.io, .fromMode(mode));
        return;
    }
    return error.Unexpected;
}

/// Creates and fills `abs`; false when the file appeared in the meantime.
fn createInPlace(fs: Fs, abs: []const u8, content: []const u8, mode: u16) !bool {
    const file = fs.openNoFollow(abs, .{ .access = .write, .create = mode, .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => return false,
        else => return e,
    };
    defer file.close(fs.io);
    try file.setPermissions(fs.io, .fromMode(mode));
    try file.writeStreamingAll(fs.io, content);
    return true;
}

/// Status of the file an atomic write replaces; null when there is none.
fn destinationStat(fs: Fs, abs: []const u8) !?Stat {
    const st = fs.lstat(abs) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    if (st.kind == .sym_link) return error.DestinationIsSymlink;
    return st;
}

const max_name_bytes = 255;
const temp_marker = ".tmp";
/// Temporary files older than this are leftovers of an interrupted write.
const stale_temp_ns = 60 * std.time.ns_per_s;

/// `.<name>.tmp` with `name` shortened so that the temporary name, with up to eight hex
/// digits after it, fits in one path component.
fn tempPrefix(buf: *[max_name_bytes]u8, base: []const u8) []const u8 {
    const keep = @min(base.len, max_name_bytes - 1 - temp_marker.len - 8);
    return std.fmt.bufPrint(buf, ".{s}{s}", .{ base[0..keep], temp_marker }) catch unreachable;
}

fn tempSibling(fs: Fs, buf: []u8, abs: []const u8) ![]u8 {
    var random: [4]u8 = undefined;
    fs.io.random(&random);
    const dir = std.fs.path.dirname(abs) orelse "/";
    const sep = if (std.mem.eql(u8, dir, "/")) "" else "/";
    var prefix_buf: [max_name_bytes]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{x}", .{
        dir, sep, tempPrefix(&prefix_buf, std.fs.path.basename(abs)), std.mem.readInt(u32, &random, .little),
    });
}

/// Removes regular files named like temporary siblings of `abs` that are older than
/// `stale_temp_ns`; a younger one may belong to a concurrent writer. Failures are ignored:
/// the write that follows reports a directory that cannot be used.
fn removeStaleTemps(fs: Fs, abs: []const u8) void {
    var prefix_buf: [max_name_bytes]u8 = undefined;
    const prefix = tempPrefix(&prefix_buf, std.fs.path.basename(abs));
    var buf: [path_cap]u8 = undefined;
    const dir_abs = std.fs.path.dirname(abs) orelse "/";
    const target = fs.follow(&buf, dir_abs) catch return;
    var dir = fs.root.openDir(fs.io, rel(target), .{ .iterate = true }) catch return;
    defer dir.close(fs.io);
    const now = Io.Timestamp.now(fs.io, .real).toNanoseconds();
    var it = dir.iterate();
    while (it.next(fs.io) catch return) |e| {
        if (!std.mem.startsWith(u8, e.name, prefix)) continue;
        const suffix = e.name[prefix.len..];
        if (suffix.len == 0 or suffix.len > 8 or !isHex(suffix)) continue;
        const st = dir.statFile(fs.io, e.name, .{ .follow_symlinks = false }) catch continue;
        if (st.kind != .file or now - st.mtime.toNanoseconds() < stale_temp_ns) continue;
        dir.deleteFile(fs.io, e.name) catch continue;
    }
}

fn isHex(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn syncDir(fs: Fs, abs: []const u8) !void {
    var buf: [path_cap]u8 = undefined;
    var dir = try fs.root.openDir(fs.io, rel(try fs.follow(&buf, abs)), .{ .iterate = true });
    defer dir.close(fs.io);
    const as_file: File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(fs.io);
}

const path_cap = Dir.max_path_bytes;

/// Resolves `abs` inside the root, following symlinks component by component. Absolute
/// link targets are re-rooted; the result is an absolute in-root path owned by the caller.
pub fn realpath(fs: Fs, gpa: std.mem.Allocator, abs: []const u8) ![]u8 {
    var out: [path_cap]u8 = undefined;
    return gpa.dupe(u8, try fs.resolveInto(&out, abs));
}

/// Path to hand to the OS for a symlink-following operation: `abs` itself on the host root,
/// the in-root resolved path otherwise.
fn follow(fs: Fs, out: *[path_cap]u8, abs: []const u8) ![]const u8 {
    if (fs.host_root) return abs;
    return fs.resolveInto(out, abs);
}

fn resolveInto(fs: Fs, out: *[path_cap]u8, abs: []const u8) ![]const u8 {
    if (abs.len > path_cap) return error.NameTooLong;
    var bufs: [2][path_cap]u8 = undefined;
    var link_buf: [path_cap]u8 = undefined;
    var cur: usize = 0;
    @memcpy(bufs[0][0..abs.len], abs);
    var pending: []const u8 = bufs[0][0..abs.len];
    var len: usize = 0;
    var hops: usize = 0;
    while (nextComponent(pending)) |next| {
        const component, const rest = next;
        pending = rest;
        if (std.mem.eql(u8, component, "..")) {
            len = std.mem.findScalarLast(u8, out[0..len], '/') orelse 0;
            continue;
        }
        if (std.mem.eql(u8, component, ".")) continue;
        const prev_len = len;
        if (len + 1 + component.len > path_cap) return error.NameTooLong;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..component.len], component);
        len += 1 + component.len;
        if ((try fs.lstatRaw(out[0..len])).kind != .sym_link) continue;
        hops += 1;
        if (hops > max_symlink_hops) return error.SymLinkLoop;
        const target = try fs.readLinkRaw(out[0..len], &link_buf);
        len = if (std.fs.path.isAbsolute(target)) 0 else prev_len;
        const need = target.len + 1 + rest.len;
        if (need > path_cap) return error.NameTooLong;
        const other = 1 - cur;
        @memcpy(bufs[other][0..target.len], target);
        bufs[other][target.len] = '/';
        @memcpy(bufs[other][target.len + 1 ..][0..rest.len], rest);
        cur = other;
        pending = bufs[other][0..need];
    }
    if (len == 0) {
        out[0] = '/';
        return out[0..1];
    }
    return out[0..len];
}

fn nextComponent(path: []const u8) ?struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimStart(u8, path, "/");
    if (trimmed.len == 0) return null;
    const end = std.mem.findScalar(u8, trimmed, '/') orelse trimmed.len;
    return .{ trimmed[0..end], trimmed[end..] };
}

/// Device and inode of `abs` (following symlinks inside the root), for same-filesystem-object
/// comparisons.
pub fn devIno(fs: Fs, abs: []const u8) !DevIno {
    var resolved_buf: [path_cap]u8 = undefined;
    const target = try fs.follow(&resolved_buf, abs);
    var path_buf: [path_cap:0]u8 = undefined;
    const sub = rel(target);
    if (sub.len > path_cap) return error.NameTooLong;
    @memcpy(path_buf[0..sub.len], sub);
    path_buf[sub.len] = 0;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(fs.root.handle, path_buf[0..sub.len :0], 0, .{ .INO = true }, &sx);
    return switch (linux.errno(rc)) {
        .SUCCESS => .{ .dev_major = sx.dev_major, .dev_minor = sx.dev_minor, .ino = sx.ino },
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

const testing = std.testing;

fn tmpFs(tmp: *testing.TmpDir) Fs {
    return .initDir(testing.io, tmp.dir);
}

test "atomic write creates, replaces and leaves no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/etc/d");
    try fs.writeFileAtomic("/etc/d/f", "one", 0o640);
    try fs.writeFileAtomic("/etc/d/f", "two", 0o640);
    const data = try fs.readFileAlloc(testing.allocator, "/etc/d/f", 100);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("two", data);
    try testing.expectEqual(@as(u16, 0o640), (try fs.stat("/etc/d/f")).mode);
    const entries = try fs.iterateDir(testing.allocator, "/etc/d");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
}

test "atomic write refuses a symlink destination" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.writeFileAtomic("/real", "x", 0o644);
    try fs.symLink("real", "/link");
    try testing.expectError(error.DestinationIsSymlink, fs.writeFileAtomic("/link", "y", 0o644));
    const data = try fs.readFileAlloc(testing.allocator, "/real", 10);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("x", data);
}

test "realpath re-roots absolute symlinks and handles dot-dot" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/usr/lib/real");
    try fs.makePath("/etc");
    try fs.symLink("/usr/lib/real", "/etc/abs");
    try fs.symLink("../usr", "/etc/rel");
    const a = try fs.realpath(testing.allocator, "/etc/abs");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/usr/lib/real", a);
    const b = try fs.realpath(testing.allocator, "/etc/rel/lib/../lib/real");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/usr/lib/real", b);
    const root = try fs.realpath(testing.allocator, "/");
    defer testing.allocator.free(root);
    try testing.expectEqualStrings("/", root);
}

test "realpath detects symlink loops" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.symLink("/b", "/a");
    try fs.symLink("/a", "/b");
    try testing.expectError(error.SymLinkLoop, fs.realpath(testing.allocator, "/a"));
}

test "iterateDir returns entries sorted by name with kinds" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/d/sub");
    try fs.writeFileAtomic("/d/b", "", 0o644);
    try fs.writeFileAtomic("/d/a", "", 0o644);
    try fs.symLink("a", "/d/c");
    const entries = try fs.iterateDir(testing.allocator, "/d");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 4), entries.len);
    try testing.expectEqualStrings("a", entries[0].name);
    try testing.expectEqualStrings("b", entries[1].name);
    try testing.expectEqualStrings("c", entries[2].name);
    try testing.expectEqual(Kind.sym_link, entries[2].kind);
    try testing.expectEqualStrings("sub", entries[3].name);
    try testing.expectEqual(Kind.directory, entries[3].kind);
}

test "devIno is stable for a path and differs between files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.writeFileAtomic("/x", "", 0o644);
    try fs.writeFileAtomic("/y", "", 0o644);
    const x1 = try fs.devIno("/x");
    const x2 = try fs.devIno("/x");
    const y = try fs.devIno("/y");
    try testing.expect(x1.eql(x2));
    try testing.expect(!x1.eql(y));
    try testing.expectEqual((try fs.stat("/x")).inode, x1.ino);
    try testing.expectError(error.FileNotFound, fs.devIno("/missing"));
}

test "stat, lstat, exists, readLink, rename and delete" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.writeFileAtomic("/f", "abc", 0o600);
    try fs.symLink("f", "/l");
    try testing.expectEqual(Kind.file, (try fs.stat("/l")).kind);
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/l")).kind);
    try testing.expectEqual(@as(u64, 3), (try fs.stat("/f")).size);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("f", try fs.readLink("/l", &buf));
    try testing.expect(fs.exists("/f"));
    try fs.rename("/f", "/g");
    try testing.expect(!fs.exists("/f"));
    try fs.deleteFile("/g");
    try fs.makePath("/t/u");
    try fs.deleteTree("/t");
    try testing.expect(!fs.exists("/t"));
}

test "following operations resolve absolute symlinks inside the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/usr/lib/data");
    try fs.writeFileAtomic("/usr/lib/data/file", "inside", 0o644);
    try fs.makePath("/etc");
    try fs.symLink("/usr/lib/data/file", "/etc/file-link");
    try fs.symLink("/usr/lib/data", "/etc/dir-link");

    const data = try fs.readFileAlloc(testing.allocator, "/etc/file-link", 100);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("inside", data);
    const via_dir = try fs.readFileAlloc(testing.allocator, "/etc/dir-link/file", 100);
    defer testing.allocator.free(via_dir);
    try testing.expectEqualStrings("inside", via_dir);

    try testing.expectEqual(Kind.file, (try fs.stat("/etc/file-link")).kind);
    try testing.expectEqual(@as(u64, 6), (try fs.stat("/etc/dir-link/file")).size);
    try testing.expect(fs.exists("/etc/file-link"));
    try testing.expect((try fs.devIno("/etc/file-link")).eql(try fs.devIno("/usr/lib/data/file")));

    const entries = try fs.iterateDir(testing.allocator, "/etc/dir-link");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("file", entries[0].name);
}

test "an absolute symlink to a path missing inside the root does not escape" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/etc");
    try fs.symLink("/etc/os-release", "/etc/escape");
    try fs.symLink("/proc/self/exe", "/etc/exe");
    try fs.symLink("/", "/etc/up");
    try testing.expectError(error.FileNotFound, fs.stat("/etc/escape"));
    try testing.expectError(error.FileNotFound, fs.readFileAlloc(testing.allocator, "/etc/escape", 10));
    try testing.expectError(error.FileNotFound, fs.devIno("/etc/exe"));
    try testing.expect(!fs.exists("/etc/escape"));
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/etc/escape")).kind);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/etc/os-release", try fs.readLink("/etc/escape", &buf));
    try testing.expect((try fs.devIno("/etc/up/etc/up/etc")).eql(try fs.devIno("/etc")));
}

test "relative symlinks with dot-dot cannot climb above the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/a/b");
    try fs.writeFileAtomic("/target", "t", 0o644);
    try fs.symLink("../../../../../target", "/a/b/up");
    const data = try fs.readFileAlloc(testing.allocator, "/a/b/up", 10);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("t", data);
}

/// A tmp root with `/etc/escape` as an absolute symlink to `target`, a directory that exists
/// next to the root (outside it) and not inside it.
fn escapeFixture(tmp: *testing.TmpDir, outside: *testing.TmpDir) !struct { Fs, []u8 } {
    const fs = tmpFs(tmp);
    try fs.makePath("/etc");
    const real = try outside.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(real);
    const target = try testing.allocator.dupe(u8, real);
    errdefer testing.allocator.free(target);
    try fs.symLink(target, "/etc/escape");
    return .{ fs, target };
}

fn outsideEntries(outside: *testing.TmpDir) !usize {
    var n: usize = 0;
    var it = outside.dir.iterate();
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "mutations through an absolute directory symlink stay inside the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    const fs, const target = try escapeFixture(&tmp, &outside);
    defer testing.allocator.free(target);

    // The link's target does not exist inside the root, so every operation fails there.
    try testing.expectError(error.FileNotFound, fs.writeFileAtomic("/etc/escape/f", "x", 0o644));
    try testing.expectError(error.FileNotFound, fs.symLink("t", "/etc/escape/l"));
    try testing.expectError(error.FileNotFound, fs.deleteFile("/etc/escape/f"));
    try testing.expectError(error.FileNotFound, fs.rename("/etc/escape/a", "/etc/b"));
    try testing.expectError(error.FileNotFound, fs.makePath("/etc/escape/sub/dir"));
    try testing.expectEqual(@as(usize, 0), try outsideEntries(&outside));
}

test "re-rooted absolute directory symlink is used for every mutation" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    const fs, const target = try escapeFixture(&tmp, &outside);
    defer testing.allocator.free(target);

    // Same absolute path inside the root: operations land there, never at the real path.
    try fs.makePath(target);
    try fs.writeFileAtomic("/etc/escape/f", "x", 0o644);
    try testing.expect(fs.exists("/etc/escape/f"));
    try fs.makePath("/etc/escape/sub/dir");
    try fs.symLink("f", "/etc/escape/l");
    try fs.rename("/etc/escape/f", "/etc/escape/g");
    try testing.expect(fs.exists("/etc/escape/g"));
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/etc/escape/l")).kind);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("f", try fs.readLink("/etc/escape/l", &buf));
    try fs.deleteFile("/etc/escape/g");
    try fs.deleteTree("/etc/escape/sub");
    try testing.expect(!fs.exists("/etc/escape/sub"));
    try testing.expectEqual(@as(usize, 0), try outsideEntries(&outside));
}

test "deleting a symlink removes the link, not its target" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/real/d");
    try fs.writeFileAtomic("/real/d/f", "x", 0o644);
    try fs.symLink("/real", "/link");
    try fs.symLink("/real/d/f", "/flink");
    try fs.deleteFile("/flink");
    try testing.expect(fs.exists("/real/d/f"));
    try fs.deleteTree("/link");
    try testing.expectError(error.FileNotFound, fs.lstat("/link"));
    try testing.expect(fs.exists("/real/d/f"));
}

test "makePath reuses a directory reached through a symlink component" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/usr/lib");
    try fs.symLink("/usr/lib", "/lib");
    try fs.makePath("/lib/x/y");
    try testing.expect(fs.exists("/usr/lib/x/y"));
    try fs.writeFileAtomic("/f", "", 0o644);
    try testing.expectError(error.NotDir, fs.makePath("/f/sub"));
}

test "makePath of the host root accepts a directory reached through a symlink" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fs = tmpFs(&tmp);
    fs.host_root = true;
    try fs.makePath("/etc/rc.d/init.d");
    try fs.symLink("rc.d/init.d", "/etc/init.d");
    try fs.makePath("/etc/init.d");
    try fs.writeFileAtomic("/etc/init.d/svc", "x", 0o755);
    try testing.expect(fs.exists("/etc/rc.d/init.d/svc"));
    try fs.writeFileAtomic("/f", "", 0o644);
    try testing.expectError(error.NotDir, fs.makePath("/f"));
}

test "rename moves a link inside a symlinked directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/real");
    try fs.symLink("/real", "/d");
    try fs.symLink("x", "/d/a");
    try fs.rename("/d/a", "/d/b");
    try testing.expect((try fs.lstat("/real/b")).kind == .sym_link);
    try testing.expectError(error.FileNotFound, fs.lstat("/real/a"));
}

fn expectContent(fs: Fs, path: []const u8, want: []const u8) !void {
    const data = try fs.readFileAlloc(testing.allocator, path, 1 << 16);
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(want, data);
}

test "writeFileInPlace creates with the mode, truncates and refuses a symlink" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/run");
    try fs.writeFileInPlace("/run/p", "12345\n", 0o644);
    try fs.writeFileInPlace("/run/p", "7\n", 0o644);
    try expectContent(fs, "/run/p", "7\n");
    try testing.expectEqual(@as(u16, 0o644), (try fs.stat("/run/p")).mode);
    try fs.symLink("p", "/run/l");
    try testing.expectError(error.DestinationIsSymlink, fs.writeFileInPlace("/run/l", "x", 0o644));
    try expectContent(fs, "/run/p", "7\n");
}

test "writeFileInPlace never follows a symlink out of the root" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outside = testing.tmpDir(.{ .iterate = true });
    defer outside.cleanup();
    try outside.dir.writeFile(testing.io, .{ .sub_path = "victim", .data = "untouched" });
    const real = try outside.dir.realPathFileAlloc(testing.io, "victim", testing.allocator);
    defer testing.allocator.free(real);
    const fs = tmpFs(&tmp);
    try fs.makePath("/run");
    try fs.symLink(real, "/run/escape");
    try testing.expectError(error.DestinationIsSymlink, fs.writeFileInPlace("/run/escape", "owned", 0o644));
    const data = try outside.dir.readFileAlloc(testing.io, "victim", testing.allocator, .limited(100));
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("untouched", data);
}

test "writeFileInPlace refuses a FIFO without blocking" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/run");
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.mknodat(tmp.dir.handle, "run/fifo", linux.S.IFIFO | 0o600, 0)));
    // Without a reader the open fails (`NoDevice`); with one the file type is refused.
    fs.writeFileInPlace("/run/fifo", "x", 0o644) catch |e| switch (e) {
        error.NoDevice, error.NotRegularFile => return,
        else => return e,
    };
    return error.TestUnexpectedResult;
}

test "as root writeFileInPlace replaces a file that another account owns" {
    if (linux.geteuid() != 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/run");
    try fs.writeFileInPlace("/run/p", "old", 0o666);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchownat(tmp.dir.handle, "run/p", 4242, 4242, 0)));
    try fs.writeFileInPlace("/run/p", "new", 0o644);
    var file = try fs.openNoFollow("/run/p", .{});
    defer file.close(testing.io);
    const info = try fileInfo(file);
    try testing.expectEqual(@as(u32, 0), info.uid);
    try testing.expectEqual(@as(u16, 0o644), info.mode);
    try expectContent(fs, "/run/p", "new");
}

const RaceCtx = struct {
    fs: Fs,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(c: *RaceCtx) void {
        var i: usize = 0;
        var buf: [64]u8 = undefined;
        while (i < 150) : (i += 1) {
            const path = std.fmt.bufPrint(&buf, "/race/{d}/x/y", .{i}) catch unreachable;
            c.fs.makePath(path) catch c.failed.store(true, .seq_cst);
        }
    }
};

test "makePath survives concurrent creators of the same path" {
    inline for (.{ false, true }) |host| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var c: RaceCtx = .{ .fs = tmpFs(&tmp) };
        c.fs.host_root = host;
        var threads: [8]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, RaceCtx.run, .{&c});
        for (threads) |t| t.join();
        try testing.expect(!c.failed.load(.seq_cst));
        try testing.expect(c.fs.exists("/race/149/x/y"));
    }
}

test "makePathMode applies the mode to new directories only" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/var");
    try fs.makePathMode("/var/log/unit", 0o750);
    try testing.expectEqual(@as(u16, 0o750), (try fs.stat("/var/log")).mode);
    try testing.expectEqual(@as(u16, 0o750), (try fs.stat("/var/log/unit")).mode);
    try testing.expectEqual(@as(u16, 0o755), (try fs.stat("/var")).mode & 0o755);
}

test "atomic write copes with the longest file names and leaves no temporary file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/d");
    for ([_]usize{ 240, 250, 255 }) |len| {
        const name = try testing.allocator.alloc(u8, len);
        defer testing.allocator.free(name);
        @memset(name, 'n');
        const path = try std.fmt.allocPrint(testing.allocator, "/d/{s}", .{name});
        defer testing.allocator.free(path);
        try fs.writeFileAtomic(path, "a", 0o644);
        try fs.writeFileAtomic(path, "b", 0o644);
        try expectContent(fs, path, "b");
        try fs.deleteFile(path);
    }
    const entries = try fs.iterateDir(testing.allocator, "/d");
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "an atomic write removes stale temporary siblings of its target only" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/d");
    const old: Io.Timestamp = .zero;
    for ([_][]const u8{ ".target.tmpdeadbeef", ".other.tmpdeadbeef", ".target.tmpnothex!" }) |name| {
        const path = try std.fmt.allocPrint(testing.allocator, "/d/{s}", .{name});
        defer testing.allocator.free(path);
        try fs.writeFileAtomic(path, "x", 0o644);
        var file = try tmp.dir.openFile(testing.io, path[1..], .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = old } });
    }
    try fs.writeFileAtomic("/d/.target.tmp1234", "young", 0o644);
    try fs.symLink("elsewhere", "/d/.target.tmpbeef");
    try fs.writeFileAtomic("/d/target", "data", 0o644);
    try testing.expect(!fs.exists("/d/.target.tmpdeadbeef"));
    try testing.expect(fs.exists("/d/.other.tmpdeadbeef"));
    try testing.expect(fs.exists("/d/.target.tmpnothex!"));
    try testing.expect(fs.exists("/d/.target.tmp1234"));
    try testing.expectEqual(Kind.sym_link, (try fs.lstat("/d/.target.tmpbeef")).kind);
    try expectContent(fs, "/d/target", "data");
}

test "stat reports the owner and a root-run atomic write keeps the owner of the file it replaces" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const fs = tmpFs(&tmp);
    try fs.makePath("/etc");
    try fs.writeFileAtomic("/etc/crontab", "one", 0o600);
    const first = try fs.stat("/etc/crontab");
    try testing.expectEqual(linux.geteuid(), first.uid);
    try testing.expectEqual(linux.getegid(), first.gid);
    try testing.expectEqual(first.uid, (try fs.lstat("/etc/crontab")).uid);
    if (linux.geteuid() != 0) return;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fchownat(tmp.dir.handle, "etc/crontab", 4242, 4343, 0)));
    try fs.writeFileAtomic("/etc/crontab", "two", 0o640);
    const after = try fs.stat("/etc/crontab");
    try testing.expectEqual(@as(u32, 4242), after.uid);
    try testing.expectEqual(@as(u32, 4343), after.gid);
    try testing.expectEqual(@as(u16, 0o640), after.mode);
    try expectContent(fs, "/etc/crontab", "two");
    // A new file belongs to root.
    try fs.writeFileAtomic("/etc/new", "x", 0o644);
    try testing.expectEqual(@as(u32, 0), (try fs.stat("/etc/new")).uid);
}
