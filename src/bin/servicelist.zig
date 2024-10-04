const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var iter = try dns.queryMDNS(
        dns.mdns_services_query,
        dns.mdns_services_resource_type,
        .{},
    );
    defer iter.deinit();
    while (try iter.next(allocator)) |message| {
        defer message.deinit();
        dnslog.logMessage(log.info, message);
    }

    var iter1 = try dns.query("_spotify-connect._tcp.local", dns.mdns_services_resource_type, .{});
    defer iter1.deinit();
    while (try iter1.next(allocator)) |message| {
        defer message.deinit();
        dnslog.logMessage(log.info, message);
    }

    var iter2 = try dns.query("_hello._tcp.local", dns.mdns_services_resource_type, .{});
    defer iter2.deinit();
    while (try iter2.next(allocator)) |message| {
        defer message.deinit();
        dnslog.logMessage(log.info, message);
    }
}
