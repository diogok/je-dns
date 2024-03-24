const std = @import("std");
const builtin = @import("builtin");

const udp = @import("socket.zig");
const data = @import("data.zig");
const nservers = @import("nservers.zig");

pub const Options = struct {};

pub fn query(allocator: std.mem.Allocator, name: []const u8, resource_type: data.ResourceType, options: Options) ![]const data.Message {
    if (isLocal(name)) {
        return try queryMDNS(allocator, name, resource_type, options);
    } else {
        return try queryDNS(allocator, name, resource_type, options);
    }
}

fn queryDNS(allocator: std.mem.Allocator, name: []const u8, resource_type: data.ResourceType, _: Options) ![]const data.Message {
    const message = data.Message{
        .header = .{
            .ID = data.mkid(),
            .number_of_questions = 1,
            .flags = .{
                .recursion_available = true,
                .recursion_desired = true,
            },
        },
        .questions = &[_]data.Question{
            .{
                .name = name,
                .resource_type = resource_type,
            },
        },
    };

    const servers = try nservers.getNameservers(allocator);
    defer allocator.free(servers);

    for (servers) |address| {
        var socket = try udp.Socket.init(allocator, address, .{});
        defer socket.deinit();

        try socket.connect();
        try message.writeTo(&socket.stream);
        try socket.send();

        var stream = try socket.receive();

        const reply = try data.Message.read(allocator, &stream);

        var replies = try allocator.alloc(data.Message, 1);
        replies[0] = reply;
        return replies;
    }

    return &[_]data.Message{};
}

fn queryMDNS(allocator: std.mem.Allocator, name: []const u8, resource_type: data.ResourceType, _: Options) ![]const data.Message {
    var replies = std.ArrayList(data.Message).init(allocator);
    defer replies.deinit();

    const message = data.Message{
        .header = .{
            .ID = data.mkid(),
            .number_of_questions = 1,
        },
        .questions = &[_]data.Question{
            .{
                .name = name,
                .resource_type = resource_type,
            },
        },
    };

    const servers = try nservers.getMulticast(allocator);
    defer allocator.free(servers);

    for (servers) |addr| {
        const addr_any = try udp.getAny(addr);
        var socket = try udp.Socket.init(allocator, addr_any, .{});
        defer socket.deinit();

        try socket.bind();
        try socket.multicast(addr);

        try message.writeTo(&socket.stream);
        try socket.sendTo(addr);

        var i: usize = 0;
        while (i < 5) : (i += 1) {
            var stream = socket.receive() catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        continue;
                    },
                    else => {
                        return err;
                    },
                }
            };

            const msg = try data.Message.read(allocator, &stream);

            var keep = false;
            if (msg.header.flags.query_or_reply == .reply) {
                for (msg.records) |r| {
                    if (std.ascii.eqlIgnoreCase(r.name, name)) {
                        keep = true;
                    }
                }
            }

            if (keep) {
                try replies.append(msg);
            } else {
                msg.deinit(allocator);
            }
        }
    }

    return try replies.toOwnedSlice();
}

fn isLocal(address: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(address, ".local") or std.ascii.endsWithIgnoreCase(address, ".local.");
}
