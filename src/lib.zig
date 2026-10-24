//! Library surface for the integration tests in `tests/`; the executable imports the same files directly.
pub const core = @import("core/root.zig");
pub const unit = @import("unit/root.zig");
pub const index = @import("index/root.zig");
pub const reconcile = @import("reconcile/root.zig");
pub const cli = @import("cli/root.zig");
pub const config = @import("config/root.zig");
pub const detect = @import("detect/root.zig");
pub const backend = @import("backend/root.zig");
pub const ops = @import("ops/root.zig");
pub const exec = @import("exec/root.zig");
