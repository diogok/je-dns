const nameservers = @import("nameservers.zig");
const socket = @import("socket.zig");
const data = @import("data.zig");
const mdns = @import("mdns.zig");

pub usingnamespace nameservers;
pub usingnamespace socket;
pub usingnamespace data;
pub usingnamespace mdns;

test {
    _ = nameservers;
    _ = socket;
    _ = data;
    _ = mdns;
}
