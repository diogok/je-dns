const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.query_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var client = dns.DNClient.init(allocator, .{});
    defer client.deinit();
    try client.query("example.com", .A);

    if (try client.next()) |record| {
        defer record.deinit(allocator);
        dnslog.logRecord(log.info, record);
    }
}
