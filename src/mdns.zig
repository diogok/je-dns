
const std = @import("std");
const testing = std.testing;
const os = std.os;
const builtin = @import("builtin");

const log = std.log.scoped(.with_mdns);

pub const ResolveOptions = struct {};

pub fn query(allocator: std.mem.Allocator, name: []const u8, resource_type: ResourceType, options: ResolveOptions) !Reply {
    const servers = try get_nameservers(allocator);
    defer allocator.free(servers);
    for (servers) |address| {
        log.info("Trying address: {any}", .{address});
        const sock = try os.socket(address.any.family, os.SOCK.DGRAM | os.SOCK.CLOEXEC, 0);
        defer os.close(sock);

        settimeout(sock) catch log.info("Unable to set timeout", .{});

        try os.connect(sock, &address.any, address.getOsSockLen());
        log.info("Connected to {any}", .{address});

        {
            var buffer: [512]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buffer);
            const writer = stream.writer();

            try writeQuery(writer, name, resource_type);
            const req = stream.getWritten();
            _ = try os.send(sock, req[0..28], 0);
        }

        {
            var buffer: [512]u8 = undefined;
            _ = try os.recv(sock, &buffer, 0);
            var stream = std.io.fixedBufferStream(&buffer);
            const reader = stream.reader();

            const reply = try readReply(allocator, reader);
            if (reply.records.len > 0) {
                return reply;
            }
        }
    }

    return error.UnableToResolve;
}

