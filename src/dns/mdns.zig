const std = @import("std");
const testing = std.testing;

const data = @import("data.zig");
const net = @import("socket.zig");

const Peer = struct {
    address: std.net.Address,
    ttl_in_seconds: u32,

    pub fn eql(self: @This(), other_peer: @This()) bool {
        if (self.address.eql(other_peer.address)) {
            return true;
        }
        return false;
    }
};

pub const mDNSService = struct {
    sockets: [2]net.Socket,

    name: []const u8,
    port: u16,

    pub fn init(name: []const u8, port: u16) !@This() {
        const ipv4 = try net.Socket.init(data.mdns_ipv4_address, .{});
        //const ipv4 = try net.Socket.init(try std.net.Address.parseIp("127.0.0.1", 8979), .{});
        try ipv4.bind();
        try ipv4.multicast();

        const ipv6 = try net.Socket.init(data.mdns_ipv6_address, .{});
        try ipv6.bind();
        try ipv6.multicast();

        return @This(){
            .sockets = .{ ipv4, ipv6 },
            .name = name,
            .port = port,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.sockets) |socket| {
            socket.deinit();
        }
    }

    /// query will query the network for other instances of this service.
    /// next call to handle will probably return new peers.
    pub fn query(self: *@This()) !void {
        // Prepare the query message
        const message = data.Message{
            .allocator = null,
            .header = .{
                .ID = 0,
                .number_of_questions = 1,
            },
            .questions = &[_]data.Question{
                .{
                    .name = self.name,
                    .resource_type = .PTR,
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

    /// Handle request to to respond with this service
    /// as well as find new peers
    /// should run constantly
    /// Might or might return a peer
    /// Should not stop on null
    pub fn handle(self: *@This(), allocator: std.mem.Allocator) !?Peer {
        var buffer: [512]u8 = undefined;
        sockets: for (self.sockets) |socket| {
            while (true) {
                const len = socket.receive(&buffer) catch continue :sockets;

                var stream = std.io.fixedBufferStream(buffer[0..len]);

                // parse the message
                // if it fails it is probably invalid message
                // so continue to try next message
                const message = try data.Message.read(allocator, &stream); //catch continue :receiving;
                defer message.deinit();

                // handle the message
                if (try self.handleMessage(message)) |peer| {
                    // if the message contained a peer, return it
                    return peer;
                    // else just continue to next message or socket
                }
            }
        }
        return null;
    }

    fn handleMessage(self: *@This(), message: data.Message) !?Peer {
        switch (message.header.flags.query_or_reply) {
            .reply => {
                return self.handleReply(message);
            },
            .query => {
                for (message.questions) |q| {
                    if (std.mem.eql(u8, q.name, self.name)) {
                        try self.respond();
                    }
                }
                return null;
            },
        }
    }

    fn handleReply(self: *@This(), message: data.Message) ?Peer {
        var name: []const u8 = "";
        var host: []const u8 = "";
        var port: u16 = 0;
        var addr: ?std.net.Address = null;
        var ttl: u32 = 0;

        for (message.records) |record| {
            if (std.mem.eql(u8, record.name, self.name) and record.resource_type == .PTR) {
                name = record.data.ptr;
            }
        }

        for (message.additional_records) |record| {
            if (std.mem.eql(u8, name, record.name) and record.resource_type == .SRV) {
                port = record.data.srv.port;
                host = record.data.srv.target;
            }
            if (std.mem.eql(u8, host, record.name) and record.resource_type == .A) {
                addr = record.data.ip;
                ttl = record.ttl;
            }
        }

        if (addr) |address| {
            return Peer{
                .address = address,
                .ttl_in_seconds = ttl,
            };
        }
        return null;
    }

    fn respond(self: *@This()) !void {
        var hostname_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
        var name_buffer: [std.posix.HOST_NAME_MAX + 1024]u8 = undefined;
        var target_buffer: [std.posix.HOST_NAME_MAX + 6]u8 = undefined;

        const hostname = std.posix.gethostname(&hostname_buffer) catch unreachable;

        const full_service_name = std.fmt.bufPrint(
            &name_buffer,
            "{s}.{s}",
            .{
                hostname,
                self.name,
            },
        ) catch unreachable;

        const target_host = std.fmt.bufPrint(
            &target_buffer,
            "{s}.local",
            .{
                hostname,
            },
        ) catch unreachable;

        const message = data.Message{
            .allocator = null,
            .header = data.Header{
                .flags = data.Flags{
                    .query_or_reply = .reply,
                },
                .number_of_answers = 1,
                .number_of_additional_resource_records = 2,
            },
            .records = &[_]data.Record{
                .{
                    .name = self.name,
                    .resource_class = .IN,
                    .resource_type = .PTR,
                    .ttl = 600,
                    .data = .{
                        .ptr = full_service_name,
                    },
                },
            },
            .additional_records = &[_]data.Record{
                .{
                    .name = full_service_name,
                    .resource_class = .IN,
                    .resource_type = .SRV,
                    .ttl = 600,
                    .data = .{
                        .srv = .{
                            .port = self.port,
                            .priority = 0,
                            .weight = 0,
                            .target = target_host,
                        },
                    },
                },
                .{
                    .name = target_host,
                    .resource_class = .IN,
                    .resource_type = .A,
                    .ttl = 600,
                    .data = .{
                        .ip = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 0),
                    },
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
};

test "Test a service" {
    var mdns = try mDNSService.init("_hello._tcp._local", 8888);
    defer mdns.deinit();
    try mdns.query();
    _ = try mdns.handle(testing.allocator);
    _ = try mdns.handle(testing.allocator);
    _ = try mdns.handle(testing.allocator);
}

/// A static list of Peers.
/// Handles expiration.
pub const Peers = struct {
    data: [64]?Peer = undefined,
    timestamps: [64]i64 = undefined,
    buffer: [64]Peer = undefined,

    /// Call to add or update a peer.
    pub fn found(self: *@This(), new_peer: Peer) void {
        // clean-up expired entries.
        self.expire();

        // loop on existing entries
        for (self.data, 0..) |existing, o| {
            // if this entry is filled
            if (existing) |peer| {
                // and is the same peer
                if (peer.eql(new_peer)) {
                    // update with new timestamp
                    self.timestamps[o] = std.time.timestamp();
                    return;
                }
            } else {
                // if this entry is null, fill with the new data
                self.data[o] = new_peer;
                self.timestamps[o] = std.time.timestamp();
                return;
            }
        }
    }

    /// Call to return list of of peers.
    pub fn peers(self: *@This()) []Peer {
        // clean-up expired entries
        self.expire();

        var i: usize = 0;
        // find entries with data (non-null)
        for (self.data) |existing| {
            if (existing) |peer| {
                self.buffer[i] = peer;
                i += 1;
            }
        }

        return self.buffer[0..i];
    }

    /// Remove expired entries.
    fn expire(self: *@This()) void {
        for (self.data, 0..) |existing, i| {
            if (existing) |peer| {
                const now = std.time.timestamp();
                const them = self.timestamps[i];
                const expires_at = them + peer.ttl_in_seconds;
                if (expires_at <= now) {
                    self.data[i] = null;
                }
            }
        }
    }
};

test "peers" {
    var peers = Peers{};

    const empty0 = peers.peers();
    try testing.expectEqual(0, empty0.len);

    const addr8080 = try std.net.Address.parseIp("127.0.0.1", 8080);
    const addr8081 = try std.net.Address.parseIp("127.0.0.1", 8081);

    peers.found(Peer{ .ttl_in_seconds = 1, .address = addr8080 });
    peers.found(Peer{ .ttl_in_seconds = 1, .address = addr8080 });
    peers.found(Peer{ .ttl_in_seconds = 2, .address = addr8081 });

    const two0 = peers.peers();
    try testing.expectEqual(2, two0.len);
    try testing.expect(two0[0].address.eql(addr8080));
    try testing.expect(two0[1].address.eql(addr8081));

    peers.timestamps[0] = 0;
    const one0 = peers.peers();
    try testing.expectEqual(1, one0.len);
    try testing.expect(one0[0].address.eql(addr8081));
}
