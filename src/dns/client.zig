//! Contains a DNS Client.

const std = @import("std");
const testing = std.testing;

const data = @import("data.zig");
const net = @import("socket.zig");
const nameservers = @import("nameservers.zig");

const num_sockets = 2;

/// Options for DNS Queries.
pub const QueryOptions = struct {
    socket_options: net.Options = .{
        .timeout_in_millis = 100,
    },
};

/// Sends a query to regular DNS or mDNS.
/// Returns a iterator to read the replies.
/// Must deinit the returned iterator.
pub fn query(
    name: []const u8,
    resource_type: data.ResourceType,
    options: QueryOptions,
) !ReplyIterator {
    if (data.isLocal(name)) {
        return queryMDNS(name, resource_type, options);
    } else {
        return queryDNS(name, resource_type, options);
    }
}

/// Sends a query to regular DNS.
/// Returns a iterator to read the replies.
/// Must deinit the returned iterator.
fn queryDNS(
    name: []const u8,
    resource_type: data.ResourceType,
    options: QueryOptions,
) !ReplyIterator {
    var sockets: [num_sockets]?net.Socket = std.mem.zeroes([num_sockets]?net.Socket);

    var iter = try nameservers.getNameserverIterator();
    defer iter.deinit();

    var i: usize = 0;
    while (try iter.next()) |address| {
        if (i >= sockets.len) {
            break;
        }
        sockets[i] = try net.Socket.init(address, options.socket_options);
        i += 1;
    }

    const message_id = try sendQuery(&sockets, name, resource_type);

    return ReplyIterator{
        .sockets = sockets,
        .message_id = message_id,
    };
}

/// Sends a query to mDNS.
/// Returns a iterator to read the replies.
/// Must deinit the returned iterator.
fn queryMDNS(
    name: []const u8,
    resource_type: data.ResourceType,
    options: QueryOptions,
) !ReplyIterator {
    var sockets: [num_sockets]?net.Socket = std.mem.zeroes([num_sockets]?net.Socket);

    sockets[0] = try net.Socket.init(data.mdns_ipv6_address, options.socket_options);
    sockets[1] = try net.Socket.init(data.mdns_ipv4_address, options.socket_options);

    for (sockets) |socket| {
        if (socket) |sock| {
            try sock.bind();
            try sock.multicast();
        }
    }

    const message_id = try sendQuery(&sockets, name, resource_type);

    return ReplyIterator{
        .sockets = sockets,
        .message_id = message_id,
    };
}

/// Send the message query and return the message ID.
fn sendQuery(sockets: []?net.Socket, name: []const u8, resource_type: data.ResourceType) !u16 {
    // Creates a new mesage ID
    const message_id = data.mkid();

    // Prepare the query message
    const message = data.Message{
        .allocator = null,
        .header = .{
            .ID = message_id,
            .number_of_questions = 1,
        },
        .questions = &[_]data.Question{
            .{
                .name = name,
                .resource_type = resource_type,
            },
        },
    };

    // get message bytes
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try message.writeTo(&stream);
    const bytes = stream.getWritten();

    // Sends the message to all sockets
    for (sockets) |socket| {
        if (socket) |sock| {
            try sock.sendBytes(bytes);
        }
    }

    // return the message id
    return message_id;
}

/// Iterates over all messages available on the sockets.
pub const ReplyIterator = struct {
    /// Sockets to send query and read messages.
    sockets: [2]?net.Socket = undefined,

    /// Current socket in use.
    current_socket: usize = 0,

    /// Current message id.
    message_id: u16 = 0,

    /// internal buffer
    buffer: [512]u8 = undefined,

    /// Reads the next response message.
    /// Callee should deinit the returned message.
    pub fn next(self: *@This(), allocator: std.mem.Allocator) !?data.Message {
        // loop until we find a reply, try all sockets or have no more messages
        while (true) {
            // check if we already read all sockets
            if (self.current_socket >= self.sockets.len) {
                // nothing else to try
                return null;
            }

            // get current server, if any
            const maybe_socket = self.sockets[self.current_socket];
            if (maybe_socket == null) {
                return null;
            }
            const socket = maybe_socket.?;

            // receive a message
            const len = socket.receive(&self.buffer) catch {
                // if this is a timeout or other error
                // it probably means there is no more message on this socket
                // so we move on to next socket
                self.current_socket += 1;
                continue;
            };

            var stream = std.io.fixedBufferStream(self.buffer[0..len]);

            // parse the message
            // if it fails it is probably invalid message
            // so continue to try next message
            const message = data.Message.read(allocator, &stream) catch continue;

            if (message.header.flags.query_or_reply != .reply) {
                // Not a reply, continue
                message.deinit();
                continue;
            }

            if (message.header.ID != self.message_id) {
                // this is not really respected generally
                //message.deinit();
                //continue;
            }

            // return the message
            return message;
        }
    }

    /// Clean-up and disconnect.
    pub fn deinit(self: *@This()) void {
        for (self.sockets) |socket| {
            if (socket) |sock| {
                sock.deinit();
            }
        }
    }
};

test "query mdns service list" {
    var iter = try queryMDNS(data.mdns_services_query, data.mdns_services_resource_type, .{});
    defer iter.deinit();
    while (try iter.next(testing.allocator)) |msg| {
        msg.deinit();
    }
}

test "query regular dns query" {
    // There is probably some better way to test it without depending on real DNS resolution
    var iter = try queryDNS("example.com", .A, .{});
    defer iter.deinit();

    const wantipv4 = try std.net.Address.parseIp4("93.184.215.14", 0);

    const msg = try iter.next(testing.allocator);
    defer msg.?.deinit();
    try testing.expect(msg != null);
    const gotipv4 = msg.?.records[0].data.ip;
    try testing.expect(gotipv4.eql(wantipv4));

    while (try iter.next(testing.allocator)) |msg0| {
        msg0.deinit();
    }
}
