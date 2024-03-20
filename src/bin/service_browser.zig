const std = @import("std");
const os = std.os;

const dns = @import("dns");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const services = dns.query(allocator, .{ .name = "_tcp._local", .resource_type = .PTR }, .{});
    log.info("TCP PTR {any}\n", .{services});
}
