const std = @import("std");
const dns = @import("dns");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var mdns = try dns.mDNSService.init("_hello._tcp.local", 8888);
    defer mdns.deinit();

    try mdns.query();

    var peer_list = dns.Peers{};

    while (true) {
        if (try mdns.handle(allocator)) |peer| {
            peer_list.found(peer);
        }
        for (peer_list.peers()) |peer| {
            log.info("Peer: {any}", .{peer});
        }
    }
}
