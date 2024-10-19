//! A demo app finding peers on local network.

const std = @import("std");
const dns = @import("dns");

const log = std.log.scoped(.mdns_demo);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    // This is our service definition.
    // We need to define the service name, following DNS-SD standard, and a port.
    const my_service = dns.Service{
        .name = "_hello._tcp.local",
        .port = 8888,
    };

    // We them create our service finder.
    // It assumes we listen on all local addresses.
    var mdns = try dns.mDNSService.init(my_service, .{});
    defer mdns.deinit();

    // We send the initial query to find peers.
    // You could send this everytime you try to find new peers.
    // It will eventually return a data in the Handle function below.
    try mdns.query();

    // This provide a limited space for storing peers found.
    // It handles expiration as well
    var peer_list = dns.Peers{};

    // Our main loop.
    while (true) {
        // Handle function will both receive queries and answer with our address.
        // As well as receive answers and return peers.
        // You should keep calling it forever to be sure we can always answer queries.
        if (try mdns.handle(allocator)) |peer| {
            peer_list.found(peer);
        }
        // Here we log all current peers.
        for (peer_list.peers()) |peer| {
            log.info("Peer: {any}", .{peer});
        }
    }
}
