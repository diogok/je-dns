const std = @import("std");
const dns = @import("dns");
const dnslog = @import("log.zig");

const log = std.log.scoped(.query_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const result = try dns.query(allocator, .{ .name = "example.com", .resource_type = .A }, .{});
    defer result.deinit();

    dnslog.logMessage(log.info, result.query);
    for (result.replies) |r| {
        dnslog.logMessage(log.info, r);
    }
}
