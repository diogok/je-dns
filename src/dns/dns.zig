const std = @import("std");

pub usingnamespace @import("socket.zig");
pub usingnamespace @import("data.zig");
pub usingnamespace @import("core.zig");
pub usingnamespace @import("dns_sd.zig");

test "all" {
    _ = @import("socket.zig");
    _ = @import("data.zig");
    _ = @import("core.zig");
    _ = @import("dns_sd.zig");
    _ = @import("nservers.zig");
}
