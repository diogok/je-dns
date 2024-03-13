const std = @import("std");
const os = std.os;

const dns = @import("dns");
const mdns = @import("mdns");

const log = std.log.scoped(.with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    {
        const reply = try dns.query(allocator, "diogok.net", .A, .{});
        defer reply.deinit();
        log.info("Reply: {any}", .{reply.records[0]});
    }

    {
        const reply = try mdns.query(allocator, "diogo-dell.local", .A, .{});
        defer reply.deinit();
        log.info("Reply: {any}", .{reply.records[0]});
    }
}
