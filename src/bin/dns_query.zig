const std = @import("std");
const os = std.os;

const dns = @import("dns");

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
    const reply = try dns.query(allocator, .{ .name = name, .resource_type = rtype }, .{});
    defer reply.deinit();
    log.info("Reply: {any}", .{reply.records[0]});
}