const std = @import("std");

const io = @import("io.zig");
const data = @import("data.zig");
const udp = @import("udp.zig");
const core = @import("core.zig");

const log = std.log.scoped(.with_dns);

pub fn listLocalServices(allocator: std.mem.Allocator) !Result {
    var services = std.ArrayList([]const u8).init(allocator);

    const result = try core.query(allocator, .{ .name = "_services._dns-sd._udp.local", .resource_type = .PTR }, .{});
    defer result.deinit();

    for (result.replies) |reply| {
        for (reply.records) |record| {
            const service = try allocator.alloc(u8, record.data.bytes.len);
            std.mem.copyForwards(u8, service, record.data.bytes);
            try services.append(service);
        }
    }

    return Result{
        .allocator = allocator,
        .services = try services.toOwnedSlice(),
    };
}

pub const Result = struct {
    allocator: std.mem.Allocator,

    services: [][]const u8,

    pub fn deinit(self: @This()) void {
        for (self.services) |service| {
            self.allocator.free(service);
        }
        self.allocator.free(self.services);
    }
};
