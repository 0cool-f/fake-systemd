// SPDX-License-Identifier: GPL-3.0-or-later
//! `network.target` and `network-online.target` for backends that have no such target: the
//! unit gets a soft dependency on each known network provider that is enabled.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../unit/model.zig");

pub fn isNetworkTarget(unit_name: []const u8) bool {
    return std.mem.eql(u8, unit_name, "network.target") or std.mem.eql(u8, unit_name, "network-online.target");
}

fn listMentions(list: []const []const u8) bool {
    for (list) |n| if (isNetworkTarget(n)) return true;
    return false;
}

/// True when `u` orders itself after or depends on a network target.
pub fn mentions(u: *const model.Unit) bool {
    return listMentions(u.requires) or listMentions(u.binds_to) or listMentions(u.wants) or listMentions(u.after);
}

pub const Enabled = struct {
    ptr: *anyopaque,
    is_enabled: *const fn (ptr: *anyopaque, service: []const u8) anyerror!bool,
    /// Replaces the lookup with a fixed set of enabled services, for tests.
    injected: ?[]const []const u8 = null,

    fn has(e: Enabled, service: []const u8) !bool {
        if (e.injected) |set| {
            for (set) |s| if (std.mem.eql(u8, s, service)) return true;
            return false;
        }
        return e.is_enabled(e.ptr, service);
    }
};

/// The providers of `providers` that are enabled, in the order of the list, without `own`.
pub fn enabledProviders(gpa: Allocator, providers: []const []const u8, own: []const u8, enabled: Enabled) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (providers) |p| {
        if (std.mem.eql(u8, p, own)) continue;
        if (try enabled.has(p)) try out.append(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn never(_: *anyopaque, _: []const u8) anyerror!bool {
    return false;
}

test "enabled providers keep the order of the list and skip the unit itself" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var dummy: u8 = 0;
    const enabled: Enabled = .{ .ptr = &dummy, .is_enabled = never, .injected = &.{ "iwd", "dhcpcd", "other" } };
    const got = try enabledProviders(arena.allocator(), &.{ "dhcpcd", "NetworkManager", "iwd" }, "iwd", enabled);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("dhcpcd", got[0]);
    const none: Enabled = .{ .ptr = &dummy, .is_enabled = never };
    try testing.expectEqual(@as(usize, 0), (try enabledProviders(arena.allocator(), &.{"dhcpcd"}, "x", none)).len);
}

test "network targets are recognised by name" {
    try testing.expect(isNetworkTarget("network.target"));
    try testing.expect(isNetworkTarget("network-online.target"));
    try testing.expect(!isNetworkTarget("basic.target"));
}
