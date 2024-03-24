const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.query_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const result = try dns.query(allocator, "example.com", .A, .{});
    defer dns.deinitAll(allocator, result);

    for (result) |r| {
        dnslog.logMessage(log.info, r);
    }
}
