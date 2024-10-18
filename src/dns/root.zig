const network_interface = @import("network_interface.zig");
const socket = @import("socket.zig");
pub const data = @import("data.zig");
pub const mdns = @import("mdns.zig");

pub usingnamespace data;
pub usingnamespace mdns;

test {
    _ = network_interface;
    _ = socket;
    _ = data;
    _ = mdns;
}
