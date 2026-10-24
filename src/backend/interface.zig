//! Backend interface (spec §11.1). A backend is a pointer plus a vtable: the init is chosen at
//! run time from detection, and test backends carry state.
const std = @import("std");
const core = @import("../core/root.zig");
const model = @import("../unit/model.zig");
const apply = @import("../reconcile/apply.zig");
const rebuild = @import("../index/rebuild.zig");
const output = @import("../cli/output.zig");
const Runner = @import("runner.zig").Runner;

pub const version = "0.1.0";

pub const Capabilities = struct {
    hard_deps: bool = false,
    soft_deps: bool = false,
    ordering: bool = false,
    supervision: bool = false,
    per_service_logger: bool = false,
    oneshot: bool = false,
    restart_policy: bool = false,
    user_services: bool = false,
    runtime_dir: bool = false,
    vendor_admin_split: bool = false,
    parametric_services: bool = false,
    /// Equivalent of boot/shutdown hooks (§6.2).
    shutdown_hooks: bool = false,
    /// Units can be translated and services controlled; false for the null backend.
    translates: bool = true,
};

/// A service of the init that fake-systemd did not generate.
pub const NativeService = struct {
    name: []const u8,
    path: []const u8,
    /// Executable extracted from the service and normalized (§6.3).
    exec: []const u8,
};

/// Returns the command words of the service defined by `content`, or null when it has none.
pub const Extractor = *const fn (gpa: std.mem.Allocator, content: []const u8) std.mem.Allocator.Error!?[]const []const u8;

/// Where native services live and how to read the command of one.
pub const NativeScan = struct {
    dirs: []const []const u8,
    extractor: Extractor,
};

pub const Status = struct {
    state: output.ActiveState,
    pid: ?u32 = null,
    /// Native status text, empty when the init provides none.
    text: []const u8 = "",
};

pub const EnableOptions = struct {
    runtime: bool = false,
    global: bool = false,
};

/// Boot-enable change reported to the user in systemd style.
pub const Change = union(enum) {
    created: struct { link: []const u8, target: []const u8 },
    removed: []const u8,
};

pub const Power = enum { reboot, poweroff, halt };

/// How a unit named in `Requires=`, `BindsTo=` or `Wants=` resolves in the backend.
pub const Dep = struct {
    /// Full unit name.
    unit: []const u8,
    /// Service name, or null when the dependency cannot be a service and has to be left out.
    service: ?[]const u8,
};

pub const GenerateInput = struct {
    unit: *const model.Unit,
    tier: core.Tier,
    /// Path of the unit fragment, recorded as `Source` in the marker.
    source: []const u8,
    src_hash: u64,
    /// Resolution of the dependencies the pipeline translated; names missing here are judged by the backend.
    deps: []const Dep = &.{},
};

pub const Generated = struct {
    /// Name of the service in the init.
    service_name: []const u8,
    files: []const apply.GeneratedFile,
};

/// What runtime operations need. `online` is false when the init is not running.
pub const Env = struct {
    ctx: *core.Context,
    runner: Runner,
    online: bool,
};

pub const Error = error{
    /// The operation is not available; the backend already reported why.
    Unsupported,
    /// A backend command exited with a failure status.
    CommandFailed,
};

pub const VTable = struct {
    name: []const u8,
    /// Generator number recorded in the index header and the marker.
    generator: u32,
    caps: Capabilities,
    native_scan: *const fn (ptr: *anyopaque, env: Env) anyerror!NativeScan,
    scan_dirs: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir,
    generate: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, input: GenerateInput) anyerror!Generated,
    enable: *const fn (ptr: *anyopaque, env: Env, service: []const u8, opts: EnableOptions) anyerror![]const Change,
    disable: *const fn (ptr: *anyopaque, env: Env, service: []const u8, opts: EnableOptions) anyerror![]const Change,
    start: *const fn (ptr: *anyopaque, env: Env, service: []const u8) anyerror!void,
    stop: *const fn (ptr: *anyopaque, env: Env, service: []const u8) anyerror!void,
    restart: *const fn (ptr: *anyopaque, env: Env, service: []const u8) anyerror!void,
    reload: *const fn (ptr: *anyopaque, env: Env, service: []const u8) anyerror!void,
    kill: *const fn (ptr: *anyopaque, env: Env, service: []const u8, signal: []const u8) anyerror!void,
    status: *const fn (ptr: *anyopaque, env: Env, service: []const u8) anyerror!Status,
    is_enabled: *const fn (ptr: *anyopaque, env: Env, service: []const u8) anyerror!output.EnabledState,
    reload_manager: *const fn (ptr: *anyopaque, env: Env) anyerror!void,
    power: *const fn (ptr: *anyopaque, env: Env, action: Power) anyerror!void,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn name(b: Backend) []const u8 {
        return b.vtable.name;
    }

    pub fn generator(b: Backend) u32 {
        return b.vtable.generator;
    }

    pub fn caps(b: Backend) Capabilities {
        return b.vtable.caps;
    }

    /// Directories and extractor for the cached native-service scan (`native_scan.scanCached`).
    pub fn nativeScan(b: Backend, env: Env) anyerror!NativeScan {
        return b.vtable.native_scan(b.ptr, env);
    }

    /// Service directories holding generated files, for rebuilding the index from markers.
    pub fn scanDirs(b: Backend, gpa: std.mem.Allocator, scope: core.Scope) anyerror![]const rebuild.ScanDir {
        return b.vtable.scan_dirs(b.ptr, gpa, scope);
    }

    /// Pure: renders the native files in memory without touching the filesystem.
    pub fn generate(b: Backend, gpa: std.mem.Allocator, input: GenerateInput) anyerror!Generated {
        return b.vtable.generate(b.ptr, gpa, input);
    }

    pub fn enable(b: Backend, env: Env, service: []const u8, opts: EnableOptions) anyerror![]const Change {
        return b.vtable.enable(b.ptr, env, service, opts);
    }

    pub fn disable(b: Backend, env: Env, service: []const u8, opts: EnableOptions) anyerror![]const Change {
        return b.vtable.disable(b.ptr, env, service, opts);
    }

    pub fn start(b: Backend, env: Env, service: []const u8) anyerror!void {
        return b.vtable.start(b.ptr, env, service);
    }

    pub fn stop(b: Backend, env: Env, service: []const u8) anyerror!void {
        return b.vtable.stop(b.ptr, env, service);
    }

    pub fn restart(b: Backend, env: Env, service: []const u8) anyerror!void {
        return b.vtable.restart(b.ptr, env, service);
    }

    pub fn reload(b: Backend, env: Env, service: []const u8) anyerror!void {
        return b.vtable.reload(b.ptr, env, service);
    }

    pub fn kill(b: Backend, env: Env, service: []const u8, signal: []const u8) anyerror!void {
        return b.vtable.kill(b.ptr, env, service, signal);
    }

    pub fn status(b: Backend, env: Env, service: []const u8) anyerror!Status {
        return b.vtable.status(b.ptr, env, service);
    }

    pub fn isEnabled(b: Backend, env: Env, service: []const u8) anyerror!output.EnabledState {
        return b.vtable.is_enabled(b.ptr, env, service);
    }

    pub fn reloadManager(b: Backend, env: Env) anyerror!void {
        return b.vtable.reload_manager(b.ptr, env);
    }

    pub fn power(b: Backend, env: Env, action: Power) anyerror!void {
        return b.vtable.power(b.ptr, env, action);
    }
};

/// `fake-systemd <version> <backend>/<generator>`, the `Generator` marker field.
pub fn generatorLine(gpa: std.mem.Allocator, backend_name: []const u8, generator: u32) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "fake-systemd {s} {s}/{d}", .{ version, backend_name, generator });
}
