// SPDX-License-Identifier: GPL-3.0-or-later
//! Native service lookup (§6.3): name candidates, executable confirmation and the decision table.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../unit/model.zig");
const Config = @import("../config/Config.zig");
const NativeService = @import("../backend/interface.zig").NativeService;

pub const Decision = union(enum) {
    /// Use this native service; nothing is generated.
    native: NativeService,
    generate,
    /// The name is taken by a native service with a different executable.
    conflict: NativeService,
};

fn stripService(name: []const u8) []const u8 {
    return std.mem.cutSuffix(u8, name, ".service") orelse name;
}

/// Candidate names in priority order: alias, name, `d` variants, `-daemon` variants, `Alias=`.
pub fn candidates(gpa: Allocator, config: Config, u: model.Unit) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const base = u.name.base();
    if (config.aliases.get(u.name.full)) |a| try out.append(gpa, a);
    try out.append(gpa, base);
    if (std.mem.endsWith(u8, base, "d") and base.len > 1) {
        try out.append(gpa, base[0 .. base.len - 1]);
    } else {
        try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}d", .{base}));
    }
    try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}-daemon", .{base}));
    try out.append(gpa, try std.fmt.allocPrint(gpa, "{s}daemon", .{base}));
    for (u.alias) |a| try out.append(gpa, stripService(a));
    return out.items;
}

fn findByName(natives: []const NativeService, names: []const []const u8, ignore_case: bool) ?NativeService {
    for (names) |want| {
        for (natives) |n| {
            const same = if (ignore_case) std.ascii.eqlIgnoreCase(n.name, want) else std.mem.eql(u8, n.name, want);
            if (same) return n;
        }
    }
    return null;
}

fn execMatches(n: NativeService, u: model.Unit, unit_exec: ?[]const u8) bool {
    const want = unit_exec orelse return false;
    if (!std.mem.eql(u8, n.exec, want)) return false;
    // Instances of a template share the executable; the instance must show in the service name.
    if (u.name.isInstance()) return std.mem.find(u8, n.name, u.name.instance.?) != null;
    return true;
}

fn findByExec(natives: []const NativeService, u: model.Unit, unit_exec: ?[]const u8, skip: ?NativeService) ?NativeService {
    for (natives) |n| {
        if (skip) |s| if (std.mem.eql(u8, s.name, n.name)) continue;
        if (execMatches(n, u, unit_exec)) return n;
    }
    return null;
}

/// Applies the decision table of §6.3. `service_name` is the name the backend would generate.
pub fn decide(
    gpa: Allocator,
    config: Config,
    natives: []const NativeService,
    u: model.Unit,
    unit_exec: ?[]const u8,
    service_name: []const u8,
) Allocator.Error!Decision {
    const names = try candidates(gpa, config, u);
    const by_name = findByName(natives, names, false) orelse findByName(natives, names, true);
    if (by_name) |cand| {
        if (execMatches(cand, u, unit_exec)) return .{ .native = cand };
        if (findByExec(natives, u, unit_exec, cand)) |other| return .{ .native = other };
        for (natives) |n| if (std.mem.eql(u8, n.name, service_name)) return .{ .conflict = n };
        return .generate;
    }
    if (findByExec(natives, u, unit_exec, null)) |other| return .{ .native = other };
    return .generate;
}

const testing = std.testing;

fn testUnit(name: []const u8, aliases: []const []const u8) !model.Unit {
    const name_mod = @import("../unit/name.zig");
    return .{ .name = try name_mod.parse(testing.allocator, name), .scope = .system, .alias = aliases };
}

const natives_fixture = [_]NativeService{
    .{ .name = "foo", .path = "/etc/dinit.d/foo", .exec = "/usr/bin/foo" },
    .{ .name = "other", .path = "/etc/dinit.d/other", .exec = "/usr/bin/bar" },
    .{ .name = "Baz", .path = "/etc/dinit.d/Baz", .exec = "/usr/bin/baz" },
};

fn run(name: []const u8, exec: ?[]const u8, svc: []const u8) !Decision {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const u = try testUnit(name, &.{});
    defer testing.allocator.free(u.name.full);
    return decide(arena.allocator(), .{}, &natives_fixture, u, exec, svc);
}

test "name and executable agree" {
    const d = try run("foo.service", "/usr/bin/foo", "foo");
    try testing.expectEqualStrings("foo", d.native.name);
}

test "name matches but another native has the executable" {
    const d = try run("foo.service", "/usr/bin/bar", "foo");
    try testing.expectEqualStrings("other", d.native.name);
}

test "name occupied by a different program conflicts when the generated name is taken" {
    const d = try run("foo.service", "/usr/bin/none", "foo");
    try testing.expectEqualStrings("foo", d.conflict.name);
}

test "name candidate with free generated name generates" {
    const d = try run("food.service", "/usr/bin/none", "food");
    try testing.expect(d == .generate);
}

test "no name candidate: executable decides" {
    const hit = try run("unrelated.service", "/usr/bin/bar", "unrelated");
    try testing.expectEqualStrings("other", hit.native.name);
    const miss = try run("unrelated.service", "/usr/bin/zzz", "unrelated");
    try testing.expect(miss == .generate);
}

test "case-insensitive candidates are tried last" {
    const d = try run("baz.service", "/usr/bin/baz", "baz");
    try testing.expectEqualStrings("Baz", d.native.name);
}

test "instance units need the instance in the native name" {
    const exe_hit = try run("foo@x.service", "/usr/bin/bar", "foo@x");
    try testing.expect(exe_hit != .native);
}
