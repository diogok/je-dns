const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.query_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var client = dns.DNSClient.init(allocator, .{});
    defer client.deinit();
    try client.query("example.com", .A);

    while (try client.next()) |message| {
        defer message.deinit();
        dnslog.logRecord(log.info, message.records[0]);
    }
}
