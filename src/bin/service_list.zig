const std = @import("std");
const os = std.os;

const dns = @import("dns");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const result = dns.query(allocator, .{ .name = "_services._dns-sd._udp.local", .resource_type = .PTR }, .{});

    dns.logMessage(log.info, result.query);
    for (result.replies) |r| {
        dns.logMessage(log.info, r);
    }
}
