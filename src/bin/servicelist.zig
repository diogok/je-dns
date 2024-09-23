const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var client = dns.DNSClient.init(allocator, .{});
    defer client.deinit();

    try client.query(dns.mdns_services_query, dns.mdns_services_resource_type);

    while (try client.next()) |message| {
        defer message.deinit();
        dnslog.logMessage(log.info, message);
    }

    try client.query("_http._tcp.local", dns.mdns_services_resource_type);

    while (try client.next()) |message| {
        defer message.deinit();
        dnslog.logMessage(log.info, message);
    }
}
