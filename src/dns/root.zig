const network_interface = @import("network_interface.zig");
const socket = @import("socket.zig");
const data = @import("data.zig");
const mdns = @import("mdns.zig");

pub usingnamespace network_interface;
pub usingnamespace socket;
pub usingnamespace data;
pub usingnamespace mdns;

test {
    _ = network_interface;
    _ = socket;
    _ = data;
    _ = mdns;
}
