const std = @import("std");
const os = std.os;

const dns = @import("dns");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const result = try dns.listLocalServices(allocator);
    defer result.deinit();

    for (result.services) |service| {
        log.info("Service found: {s}", .{service});
    }
}
