const std = @import("std");

pub usingnamespace @import("data.zig");
pub usingnamespace @import("core.zig");
pub usingnamespace @import("dns_sd.zig");

test "all" {
    _ = @import("udp.zig");
    _ = @import("data.zig");
    _ = @import("io.zig");
    _ = @import("core.zig");
    _ = @import("dnssd.zig");
    _ = @import("nsservers.zig");
}
