const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "fake-systemd", .root_module = root });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const links = b.addSystemCommand(&.{
        "sh", "-c", "ln -sfn fake-systemd \"$1/systemctl\" && ln -sfn fake-systemd \"$1/journalctl\"", "sh",
    });
    links.addDirectoryArg(.{ .relative = .{ .base = .install_bin } });
    links.has_side_effects = true;
    links.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&links.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run fake-systemd").dependOn(&run_cmd.step);

    const lib = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fake_systemd", .module = lib }},
    });

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = integration })).step);
}
