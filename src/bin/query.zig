const std = @import("std");
const dns = @import("dns");
const dnslog = @import("dnslog.zig");

const log = std.log.scoped(.query_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        return error.WrongNumberOfArgument;
    }

    const name: []const u8 = args[1];
    const rtype = std.meta.stringToEnum(dns.ResourceType, args[2]) orelse .A;
    const result = try dns.query(allocator, name, rtype, .{});
    defer dns.deinitAll(allocator, result);

    for (result) |r| {
        dnslog.logMessage(log.info, r);
    }
}
