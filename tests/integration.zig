// SPDX-License-Identifier: GPL-3.0-or-later
test {
    _ = @import("enable_tests.zig");
    _ = @import("reload_tests.zig");
    _ = @import("query_tests.zig");
    _ = @import("mode_tests.zig");
    _ = @import("misc_tests.zig");
    _ = @import("cache_tests.zig");
    _ = @import("golden_tests.zig");
    _ = @import("dinit_tests.zig");
    _ = @import("runit_tests.zig");
    _ = @import("s6_tests.zig");
    _ = @import("s6_rc_tests.zig");
    _ = @import("openrc_tests.zig");
    _ = @import("exec_tests.zig");
    _ = @import("timer_tests.zig");
    _ = @import("timer_runtime_tests.zig");
    _ = @import("timer_exe_tests.zig");
    _ = @import("timers_tests.zig");
}
