const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.query_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var iter = try dns.query(allocator, "example.com", .A, .{});
    defer iter.deinit();

    if (try iter.next()) |record| {
        defer record.deinit(allocator);
        dnslog.logRecord(log.info, record);
    }
}
