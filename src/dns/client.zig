//! Contains a DNS Client.

const std = @import("std");
const testing = std.testing;

const data = @import("data.zig");
const net = @import("socket.zig");

/// Options for DNS Queries.
pub const QueryOptions = struct {
    socket_options: net.Options = .{
        .timeout_in_millis = 100,
    },
};

pub const query = queryMDNS;

/// Sends a query to mDNS.
/// Returns a MessageIterator to read the response.
/// Most deinit the returned MessageIterator.
pub fn queryMDNS(
    name: []const u8,
    resource_type: data.ResourceType,
    options: QueryOptions,
) !MessageIterator {
    var self = MessageIterator{};

    self.sockets[0] = try net.Socket.init(data.mdns_ipv6_address, options.socket_options);
    self.sockets[1] = try net.Socket.init(data.mdns_ipv4_address, options.socket_options);

    for (self.sockets) |socket| {
        try socket.bind();
        try socket.multicast();
    }

    try self.send(name, resource_type);

    return self;
}

/// Iterates over all messages available on the sockets.
pub const MessageIterator = struct {
    /// Sockets to send query and read messages.
    sockets: [2]net.Socket = undefined,

    /// Current socket in use.
    current_socket: usize = 0,

    /// Current message id.
    current_message_id: u16 = 0,

    /// internal buffer
    buffer: [512]u8 = undefined,

    /// Query for some DNS records.
    pub fn send(self: *@This(), name: []const u8, resource_type: data.ResourceType) !void {
        // reset socket reading
        self.current_socket = 0;

        // Creates a new mesage ID
        // because we can receive any mDNS package, this will filter only answers to our query
        self.current_message_id = data.mkid();

        // Prepare the query message
        const message = data.Message{
            .allocator = null,
            .header = .{
                .ID = self.current_message_id,
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
        var stream = std.io.fixedBufferStream(&self.buffer);
        try message.writeTo(&stream);
        const bytes = stream.getWritten();

        // Sends the message to all sockets
        for (self.sockets) |socket| {
            try socket.sendBytes(bytes);
        }
    }

    /// Reads the next response message.
    pub fn next(self: *@This(), allocator: std.mem.Allocator) !?data.Message {
        // loop until we find a reply, try all sockets or have no more messages
        while (true) {
            // check if we already read all sockets
            if (self.current_socket >= self.sockets.len) {
                // nothing else to try
                return null;
            }

            // get current server
            const socket = self.sockets[self.current_socket];

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

            if (message.header.ID != self.current_message_id) {
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
            socket.deinit();
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
