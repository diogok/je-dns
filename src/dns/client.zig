//! Contains a DNS Client.

const std = @import("std");
const testing = std.testing;

const data = @import("data.zig");
const net = @import("socket.zig");

/// Options for DNSClient.
pub const mDNSClientOptions = struct {
    socket_options: net.Options = .{
        .timeout_in_millis = 100,
    },
};

/// mDNSClient, for querying and handling mDNS requests.
/// Works for IPv4 and IPv6.
pub const mDNSClient = struct {
    allocator: std.mem.Allocator,
    sockets: [2]net.Socket,

    /// Current socket in use.
    current_socket: usize = 0,

    /// Current message id.
    current_message_id: u16 = 0,

    /// Creates a new mDNSClient with given options.
    pub fn init(allocator: std.mem.Allocator, options: mDNSClientOptions) !@This() {
        var self = @This(){
            .allocator = allocator,
            .sockets = undefined,
        };

        self.sockets[0] = try net.Socket.init(data.mdns_ipv6_address, options.socket_options);
        self.sockets[1] = try net.Socket.init(data.mdns_ipv4_address, options.socket_options);

        for (self.sockets) |socket| {
            try socket.bind();
            try socket.multicast();
        }

        return self;
    }

    /// Query for some DNS records.
    pub fn query(self: *@This(), name: []const u8, resource_type: data.ResourceType) !void {
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
                // Only one query
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
        for (self.sockets) |socket| {
            try socket.sendBytes(bytes);
        }
    }

    /// Reads the next response message.
    pub fn next(self: *@This()) !?data.Message {
        while (true) {
            // check if we already read all sockets
            if (self.current_socket >= self.sockets.len) {
                // nothing else to try
                return null;
            }

            // get current server
            const socket = self.sockets[self.current_socket];

            var buffer: [512]u8 = undefined;

            // receive a message
            _ = socket.receive(&buffer) catch {
                // if this is a timeout or other error
                // it probably means there is no more message on this socket
                // so we move on to next socket
                self.current_socket += 1;
                continue;
            };

            var stream = std.io.fixedBufferStream(&buffer);

            // parse the message
            // if it fails it is probably invalid message
            // so continue to try next message
            const message = data.Message.read(self.allocator, &stream) catch continue;

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

test "query sample" {
    var client = try mDNSClient.init(testing.allocator, .{});
    defer client.deinit();
    try client.query(data.mdns_services_query, data.mdns_services_resource_type);
    while (try client.next()) |msg| {
        msg.deinit();
    }
}
