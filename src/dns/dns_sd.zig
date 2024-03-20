const std = @import("std");

const io = @import("io.zig");
const data = @import("data.zig");
const udp = @import("udp.zig");
const core = @import("core.zig");

const log = std.log.scoped(.with_dns);
