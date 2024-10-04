const nameservers = @import("nameservers.zig");
const socket = @import("socket.zig");
const data = @import("data.zig");
const client = @import("client.zig");
//const server = @import("server.zig");

pub usingnamespace nameservers;
pub usingnamespace socket;
pub usingnamespace data;
pub usingnamespace client;
//pub usingnamespace server;

test {
    _ = nameservers;
    _ = socket;
    _ = data;
    _ = client;
    //_ = server;
}
