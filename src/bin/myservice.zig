const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const records = [_]dns.Record{
        dns.Record{
            .name = "_hello._tcp.local",
            .resource_type = .PTR,
            .resource_class = .IN,
            .ttl = 6000,
            .data = dns.RecordData{
                .ptr = "mememe._hello._tcp.local",
            },
        },
    };

    var mDNSServer = try dns.mDNSServer.init(allocator, &records, .{});
    defer mDNSServer.deinit();

    while (true) {
        try mDNSServer.handle();
    }
}
