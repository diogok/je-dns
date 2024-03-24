const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const net = @import("socket.zig");
const data = @import("data.zig");
const nservers = @import("nservers.zig");

pub const Options = struct {
    max_messages: usize = 5,
    attempts_per_nameserver: usize = 3,
    socket_options: net.Options = .{},
};

pub fn query(allocator: std.mem.Allocator, name: []const u8, resource_type: data.ResourceType, options: Options) ![]const data.Message {
    const useMDNS = isLocal(name);
    const max = if (useMDNS) options.max_messages else 1;

    const message = data.Message{
        .header = .{
            .ID = data.mkid(),
            .number_of_questions = 1,
            .flags = .{
                .recursion_available = !useMDNS,
                .recursion_desired = !useMDNS,
            },
        },
        .questions = &[_]data.Question{
            .{
                .name = name,
                .resource_type = resource_type,
            },
        },
    };

    var replies = std.ArrayList(data.Message).init(allocator);
    defer replies.deinit();

    const servers = try nservers.getNameserversFor(allocator, name);
    defer allocator.free(servers);

    servers: for (servers) |addr| {
        var socket = try net.Socket.init(
            allocator,
            addr,
            options.socket_options,
        );
        defer socket.deinit();

        try message.writeTo(&socket.stream);
        try socket.send();

        var i: usize = 0;
        while (i < options.attempts_per_nameserver) : (i += 1) {
            var stream = socket.receive() catch continue;
            const msg = data.Message.read(allocator, &stream) catch continue;

            var keep = false;
            if (msg.header.flags.query_or_reply == .reply) {
                records: for (msg.records) |r| {
                    if (std.ascii.eqlIgnoreCase(r.name, name)) {
                        keep = true;
                        break :records;
                    }
                }
            }

            if (keep) {
                try replies.append(msg);
            } else {
                msg.deinit(allocator);
            }

            if (replies.items.len == max) {
                break :servers;
            }
        }
    }

    return try replies.toOwnedSlice();
}

fn isLocal(address: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(address, ".local") or std.ascii.endsWithIgnoreCase(address, ".local.");
}
