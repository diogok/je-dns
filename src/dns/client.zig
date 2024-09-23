//! Contains a DNS Client.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const net = @import("socket.zig");
const ns = @import("nameservers.zig");

const data = @import("data.zig");

/// Options for DNSClient.
pub const Options = struct {
    socket_options: net.Options = .{
        .timeout_in_millis = 100,
    },
};

/// DNSClient, for querying and handling DNS requests.
/// Works for IPv4 and IPv6.
/// Main goal is to work with mDNS and DNS-SD, but should work with any request.
/// It will query all available namesevers.
pub const DNSClient = struct {
    allocator: std.mem.Allocator,
    options: Options,

    /// All nameservers sockets.
    sockets: ?[]*net.Socket = null,
    /// Current nameserver in use.
    curr: usize = 0,

    /// Creates a new DNSClient with given options.
    pub fn init(allocator: std.mem.Allocator, options: Options) @This() {
        return @This(){
            .allocator = allocator,
            .options = options,
        };
    }

    /// Query for some DNS records.
    pub fn query(self: *@This(), name: []const u8, resource_type: data.ResourceType) !void {
        // .local domains are handled differently.
        const local = data.isLocal(name);

        // First, connect to all nameservers.
        try self.connect(local);

        // Prepare the query message
        const message = data.Message{
            .allocator = null,
            .header = .{
                .ID = data.mkid(), // Creates a new mesage ID
                .flags = .{
                    // For .local, you don't want recursion.
                    // It should resolve whithin your network.
                    .recursion_available = !local,
                    .recursion_desired = !local,
                },
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

        // Sends the message to all nameservers
        try self.send(message);
    }

    /// Connect to all available nameservers
    fn connect(self: *@This(), local: bool) !void {
        // First we disconnect it any connection is already up
        self.disconnect();

        // Get all nameservers.
        const servers = try ns.getNameservers(self.allocator, local);
        defer self.allocator.free(servers);
        if (servers.len == 0) {
            return error.NoServerFound;
        }

        // Prepare all the Sockets
        var i: usize = 0;
        var sockets = try self.allocator.alloc(*net.Socket, servers.len);
        errdefer {
            for (sockets[0..i]) |sock| {
                self.allocator.destroy(sock);
            }
            self.allocator.free(sockets);
        }

        // Connect to all servers
        for (servers) |addr| {
            const socket = try net.Socket.init(addr, self.options.socket_options);
            sockets[i] = try self.allocator.create(net.Socket);
            sockets[i].* = socket;
            i += 1;
        }
        self.sockets = sockets;
    }

    /// Sends the message to all connected serves.
    fn send(self: *@This(), message: data.Message) !void {
        for (self.sockets.?) |socket| {
            try message.writeTo(socket.stream());
            try socket.send();
        }
    }

    /// Reads the next (or first) response message.
    /// It will read from each server interleaved.
    pub fn next(self: *@This()) !?data.Message {
        var count: u8 = 0;
        // Because we use short timeout, some messages may need to be retried.
        // This is needed mostly to wait for all nodes to respond to multicast requests (mDNS).
        // but it will only loop on no response.
        while (count <= 9) : (count += 1) {
            // get current server
            const socket = self.sockets.?[self.curr];

            // receive a message, ignore if it fails, probably a timeout or no response
            var stream = socket.receive() catch continue;

            // parse the message, if it fails it is probably invalid message so ignore
            const message = data.Message.read(self.allocator, &stream) catch continue;

            // use next server
            self.curr += 1;
            if (self.curr == self.sockets.?.len) {
                // if last server, return to first
                self.curr = 0;
            }

            // return the message
            return message;
        }

        // At this points, there is nothing else to read.
        self.disconnect();
        return null;
    }

    /// Disconnect from all connected servers.
    fn disconnect(self: *@This()) void {
        if (self.sockets) |sockets| {
            for (sockets) |socket| {
                socket.deinit();
                self.allocator.destroy(socket);
            }
            self.allocator.free(sockets);
            self.sockets = null;
        }
        self.curr = 0;
    }

    /// Clean-up and disconnect.
    pub fn deinit(self: *@This()) void {
        self.disconnect();
    }
};

test "query sample" {
    var client = DNSClient.init(testing.allocator, .{});
    defer client.deinit();

    // There is probably some better way to test it without depending on real DNS resolution
    try client.query("example.com", .A);
    const wantipv4 = try std.net.Address.parseIp4("93.184.215.14", 0);

    const msg = try client.next();
    defer msg.?.deinit();
    try testing.expect(msg != null);
    const gotipv4 = msg.?.records[0].data.ip;
    try testing.expect(gotipv4.eql(wantipv4));

    while (try client.next()) |msg0| {
        msg0.deinit();
    }
}
