const network_interface = @import("network_interface.zig");
const socket = @import("socket.zig");
pub const data = @import("data.zig");
pub const mdns = @import("mdns.zig");

/// Common data structures and IO for DNS messages.
pub usingnamespace data;

/// mDNS and DNS-SD service annoucing and finder.
pub usingnamespace mdns;

test {
    _ = network_interface;
    _ = socket;
    _ = data;
    _ = mdns;
}
