//! Pure three-way decision for one generated file (§8.1, §9).
const std = @import("std");

pub const Verb = enum {
    /// A verb acting on the unit (`enable`, `start`, ...).
    explicit,
    daemon_reload,
};

pub const Action = enum {
    none,
    /// Write the new content over the file (or create it).
    write,
    /// Keep the user's file and save the new content as `.fsnew`.
    keep_local_save_fsnew,
    /// Delete the generated file and drop it from the index.
    remove,
    /// Save the modified file as `.fssave`, delete it and drop it from the index.
    move_fssave,
    /// Keep the index entry, flagged `missing`, without regenerating.
    mark_missing,
    /// The marker is gone: the file is native, the entry becomes `native`.
    adopt_native,
};

pub const Notice = enum {
    local_changes_kept,
    source_removed_modified_saved,
    file_missing,
    marker_removed,

    pub const Level = enum { notice, info };

    pub fn level(n: Notice) Level {
        return switch (n) {
            .marker_removed => .info,
            else => .notice,
        };
    }
};

pub const Current = union(enum) {
    absent,
    present: struct {
        /// Hash of the content after the marker (or of the whole file without a marker).
        body_hash: u64,
        has_marker: bool,
    },
};

pub const Input = struct {
    /// `out_hash` recorded when fake-systemd wrote the file; null when the file has no index entry.
    original: ?u64,
    current: Current,
    /// Body hash of what would be generated now; null when the source unit is gone.
    new: ?u64,
    verb: Verb,
    /// The entry was already flagged `missing`, so the notice is not repeated.
    already_missing: bool = false,
};

pub const Decision = struct {
    action: Action,
    notice: ?Notice = null,
};

pub fn decide(in: Input) Decision {
    const cur = switch (in.current) {
        .absent => return decideAbsent(in),
        .present => |p| p,
    };
    if (!cur.has_marker) return .{ .action = .adopt_native, .notice = .marker_removed };

    const new = in.new orelse {
        if (in.original != null and in.original.? == cur.body_hash) return .{ .action = .remove };
        return .{ .action = .move_fssave, .notice = .source_removed_modified_saved };
    };
    if (in.original) |orig| {
        const unmodified = cur.body_hash == orig;
        if (unmodified) {
            return if (new == orig) .{ .action = .none } else .{ .action = .write };
        }
        if (new == orig) return .{ .action = .none };
    } else if (cur.body_hash == new) {
        return .{ .action = .none };
    }
    // The user's file differs from the original and the generator produced something new.
    // When the file already equals the new content, rewriting only refreshes marker and index.
    if (cur.body_hash == new) return .{ .action = .write };
    return .{ .action = .keep_local_save_fsnew, .notice = .local_changes_kept };
}

fn decideAbsent(in: Input) Decision {
    if (in.new == null) return .{ .action = .remove };
    return switch (in.verb) {
        .explicit => .{ .action = .write },
        .daemon_reload => .{
            .action = .mark_missing,
            .notice = if (in.already_missing) null else .file_missing,
        },
    };
}

const testing = std.testing;

fn present(h: u64) Current {
    return .{ .present = .{ .body_hash = h, .has_marker = true } };
}

const O = 1;
const U = 2; // user-modified content
const N = 3; // new generator output

fn expectDecision(want: Action, notice: ?Notice, in: Input) !void {
    const d = decide(in);
    try testing.expectEqual(want, d.action);
    try testing.expectEqual(notice, d.notice);
}

test "row 1: current = original, new = original -> none" {
    try expectDecision(.none, null, .{ .original = O, .current = present(O), .new = O, .verb = .daemon_reload });
}

test "row 2: current = original, new differs -> write" {
    try expectDecision(.write, null, .{ .original = O, .current = present(O), .new = N, .verb = .explicit });
}

test "row 3: current differs, new = original -> local change stays" {
    try expectDecision(.none, null, .{ .original = O, .current = present(U), .new = O, .verb = .daemon_reload });
}

test "row 4: current differs, new differs -> keep local, save .fsnew" {
    try expectDecision(.keep_local_save_fsnew, .local_changes_kept, .{ .original = O, .current = present(U), .new = N, .verb = .explicit });
}

test "row 4 corner: user already made the file equal to the new content" {
    try expectDecision(.write, null, .{ .original = O, .current = present(N), .new = N, .verb = .explicit });
}

test "row 5: source removed, current = original -> remove" {
    try expectDecision(.remove, null, .{ .original = O, .current = present(O), .new = null, .verb = .daemon_reload });
}

test "row 6: source removed, current differs -> move to .fssave" {
    try expectDecision(.move_fssave, .source_removed_modified_saved, .{ .original = O, .current = present(U), .new = null, .verb = .daemon_reload });
}

test "row 7: file absent during daemon-reload -> mark missing, notice once" {
    try expectDecision(.mark_missing, .file_missing, .{ .original = O, .current = .absent, .new = N, .verb = .daemon_reload });
    try expectDecision(.mark_missing, null, .{ .original = O, .current = .absent, .new = N, .verb = .daemon_reload, .already_missing = true });
}

test "row 8: file absent during an explicit verb -> regenerate" {
    try expectDecision(.write, null, .{ .original = O, .current = .absent, .new = N, .verb = .explicit });
    try expectDecision(.write, null, .{ .original = O, .current = .absent, .new = O, .verb = .explicit, .already_missing = true });
}

test "row 9: marker removed -> adopt as native, never .fssave" {
    const no_marker: Current = .{ .present = .{ .body_hash = U, .has_marker = false } };
    try expectDecision(.adopt_native, .marker_removed, .{ .original = O, .current = no_marker, .new = N, .verb = .daemon_reload });
    try expectDecision(.adopt_native, .marker_removed, .{ .original = O, .current = no_marker, .new = null, .verb = .daemon_reload });
    try expectDecision(.adopt_native, .marker_removed, .{ .original = O, .current = no_marker, .new = O, .verb = .explicit });
    try testing.expectEqual(Notice.Level.info, Notice.marker_removed.level());
    try testing.expectEqual(Notice.Level.notice, Notice.local_changes_kept.level());
}

test "source removed and file already absent -> remove entry" {
    try expectDecision(.remove, null, .{ .original = O, .current = .absent, .new = null, .verb = .daemon_reload });
}

test "no index entry: unknown original is treated conservatively" {
    try expectDecision(.none, null, .{ .original = null, .current = present(N), .new = N, .verb = .explicit });
    try expectDecision(.keep_local_save_fsnew, .local_changes_kept, .{ .original = null, .current = present(U), .new = N, .verb = .explicit });
    try expectDecision(.write, null, .{ .original = null, .current = .absent, .new = N, .verb = .explicit });
    try expectDecision(.move_fssave, .source_removed_modified_saved, .{ .original = null, .current = present(U), .new = null, .verb = .daemon_reload });
}
