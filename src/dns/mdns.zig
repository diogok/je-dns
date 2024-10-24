//! This implements a mDNS DNS-SD service finder and responder.
//! It can anounce our service as well as find peers on the network.

const std = @import("std");
const testing = std.testing;

const data = @import("data.zig");
const net = @import("socket.zig");
const netif = @import("network_interface.zig");

/// This is another instance of our service in this network.
pub const Peer = struct {
    address: std.net.Address,
    ttl_in_seconds: u32,

    pub fn eql(self: @This(), other_peer: @This()) bool {
        if (self.address.eql(other_peer.address)) {
            return true;
        }
        return false;
    }
};

/// Our service definition.
pub const Service = struct {
    name: []const u8,
    port: u16,
};

/// Max size of a hostname.
const HOST_NAME_MAX: usize = 64;

/// Options for the mDNSService instance.
pub const mDNSServiceOptions = struct {
    ttl_in_seconds: u32 = 600,
    socket_options: net.Options = .{},
};

/// The main struct, contains the logic to find and announce mDNS services.
pub const mDNSService = struct {
    /// One socket for IPv4 and another for IPv6.
    sockets: [2]net.Socket,

    /// Name of the service
    name: []const u8,
    /// Port of the service
    port: u16,
    /// TTL of the DNS records we will send
    ttl_in_seconds: u32,

    /// Creates a new instance of this struct.
    /// Should call deinit on the returned object once done.
    pub fn init(service: Service, options: mDNSServiceOptions) !@This() {
        const ipv4 = try net.Socket.init(data.mdns_ipv4_address, .{});
        try ipv4.bind();
        try ipv4.multicast();

        const ipv6 = try net.Socket.init(data.mdns_ipv6_address, .{});
        try ipv6.bind();
        try ipv6.multicast();

        return @This(){
            .sockets = .{ ipv4, ipv6 },
            .name = service.name,
            .port = service.port,
            .ttl_in_seconds = options.ttl_in_seconds,
        };
    }

    /// Clear used resources.
    /// Close sockets.
    pub fn deinit(self: *@This()) void {
        for (self.sockets) |socket| {
            socket.deinit();
        }
    }

    /// This will query the network for other instances of this service.
    /// The next call to handle will probably return new peers.
    pub fn query(self: *@This()) !void {
        // get message bytes
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        // Prepare the query message
        const header = data.Header{
            .ID = 0,
            .number_of_questions = 1,
        };
        try header.writeTo(&stream);

        const question = data.Question{
            .name = self.name,
            .resource_type = .PTR,
        };
        try question.writeTo(&stream);

        // Sends the message to all sockets
        const bytes = stream.getWritten();
        for (self.sockets) |socket| {
            try socket.sendBytes(bytes);
        }
    }

    /// Handle queries to respond with this service
    /// It also finds new peers if query was called called before
    /// It Should run constantly
    /// Might or might return a peer
    /// Should not stop on null
    pub fn handle(self: *@This()) !?Peer {
        var buffer: [512]u8 = undefined;
        sockets: for (self.sockets) |socket| {
            receiving: while (true) {
                const len = socket.receive(&buffer) catch continue :sockets;

                var stream = std.io.fixedBufferStream(buffer[0..len]);

                // parse the message
                // if it fails it is probably invalid message
                // so continue to try next message
                var message_reader = data.messageReader(&stream) catch continue :receiving;

                // handle the message
                if (try self.handleMessage(&message_reader, socket.getFamily())) |peer| {
                    // if the message contained a peer, return it
                    return peer;
                    // else just continue to next message or socket
                }
            }
        }
        return null;
    }

    /// This funtions check if this is a query or reply.
    fn handleMessage(self: *@This(), message_reader: anytype, family: net.Family) !?Peer {
        switch (message_reader.header.flags.query_or_reply) {
            .reply => {
                return try self.handleReply(message_reader);
            },
            .query => {
                while (try message_reader.nextQuestion()) |q| {
                    if (std.mem.eql(u8, q.name, self.name)) {
                        try self.respond(family);
                    }
                }
                return null;
            },
        }
    }

    /// If it is a reply, check if this contains a Peer to our service and return it.
    /// If this reply is not about our service, returns null.
    fn handleReply(self: *@This(), message_reader: anytype) !?Peer {
        var buffer: [data.NAME_MAX_SIZE]u8 = undefined;
        var name: []const u8 = "";
        var host: []const u8 = "";
        var port: u16 = 0;
        var addr: ?std.net.Address = null;
        var ttl: u32 = 0;

        while (try message_reader.nextRecord()) |record| {
            if (std.mem.eql(u8, record.name, self.name) and record.resource_type == .PTR) {
                std.mem.copyForwards(u8, &buffer, record.data.ptr);
                name = buffer[0..record.data.ptr.len];
            }
            if (std.mem.eql(u8, name, record.name) and record.resource_type == .SRV) {
                std.mem.copyForwards(u8, &buffer, record.data.srv.target);
                host = buffer[0..record.data.srv.target.len];
                port = record.data.srv.port;
            }
            if (std.mem.eql(u8, host, record.name) and record.resource_type == .A) {
                addr = record.data.ip;
                ttl = record.ttl;
            }
            if (std.mem.eql(u8, host, record.name) and record.resource_type == .AAAA) {
                addr = record.data.ip;
                ttl = record.ttl;
            }
        }

        // If we found an address
        if (addr) |*address| {
            // check if this is not our own address
            var netif_iter = netif.NetworkInterfaceAddressIterator.init();
            defer netif_iter.deinit();
            while (netif_iter.next()) |my_addr| {
                if (address.eql(my_addr.address)) {
                    return null;
                }
            }
            address.setPort(port);

            // return found peer
            return Peer{
                .address = address.*,
                .ttl_in_seconds = ttl,
            };
        }

        // if nothing found, return null
        return null;
    }

    /// Response with our service information.
    fn respond(self: *@This(), family: net.Family) !void {
        // Prepare the names we are going to send.
        var hostname_buffer: [HOST_NAME_MAX]u8 = undefined;
        var target_buffer: [data.NAME_MAX_SIZE]u8 = undefined;
        var name_buffer: [data.NAME_MAX_SIZE]u8 = undefined;

        _ = std.c.gethostname(&hostname_buffer, HOST_NAME_MAX);
        const hostname = std.mem.span(@as([*c]u8, &hostname_buffer));

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

        // Query network interface addresses
        var netif_iter = netif.NetworkInterfaceAddressIterator.init();
        defer netif_iter.deinit();

        // Count how many addresses we have to send
        var hosts_count: u8 = 0;
        while (netif_iter.next()) |a| {
            // Skip localhost
            if (a.address.eql(net.ipv4_localhost) or a.address.eql(net.ipv6_localhost)) {
                continue;
            }
            // only send active addresses
            if (!a.up) {
                continue;
            }
            // only send if the same family as requested
            if (family == .IPv4 and a.family == .IPv4) {
                hosts_count += 1;
            } else if (family == .IPv6 and a.family == .IPv6) {
                hosts_count += 1;
            }
        }
        netif_iter.reset();

        // prepare message bytes
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);

        const header = data.Header{
            .flags = data.Flags{
                .query_or_reply = .reply,
            },
            .number_of_answers = 1,
            .number_of_additional_resource_records = 1 + hosts_count,
        };
        try header.writeTo(&stream);

        // Send our service full name
        var record = data.Record{
            .name = self.name,
            .resource_type = .PTR,
            .ttl = self.ttl_in_seconds,
            .data = .{
                .ptr = full_service_name,
            },
        };
        try record.writeTo(&stream);

        // Send the port and host
        record = data.Record{
            .name = full_service_name,
            .resource_type = .SRV,
            .ttl = self.ttl_in_seconds,
            .data = .{
                .srv = .{
                    .port = self.port,
                    .priority = 0,
                    .weight = 0,
                    .target = target_host,
                },
            },
        };
        try record.writeTo(&stream);

        // send available relevant addresses for our host
        while (netif_iter.next()) |addr| {
            if (!addr.up) {
                continue;
            }
            if (addr.address.eql(net.ipv4_localhost) or addr.address.eql(net.ipv6_localhost)) {
                continue;
            }
            if (family == .IPv4 and addr.family == .IPv4) {
                record = data.Record{
                    .name = target_host,
                    .resource_type = .A,
                    .ttl = self.ttl_in_seconds,
                    .data = .{
                        .ip = addr.address,
                    },
                };
                try record.writeTo(&stream);
            } else if (family == .IPv6 and addr.family == .IPv6) {
                record = data.Record{
                    .name = target_host,
                    .resource_type = .AAAA,
                    .ttl = self.ttl_in_seconds,
                    .data = .{
                        .ip = addr.address,
                    },
                };
                try record.writeTo(&stream);
            }
        }

        // Sends the message to all sockets
        const bytes = stream.getWritten();
        for (self.sockets) |socket| {
            try socket.sendBytes(bytes);
        }
    }
};

test "Test a service" {
    const service = Service{ .name = "_hello._tcp._local", .port = 8888 };
    var mdns = try mDNSService.init(service, .{});
    defer mdns.deinit();
    try mdns.query();
    _ = try mdns.handle();
    _ = try mdns.handle();
    _ = try mdns.handle();
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
                if (peer.ttl_in_seconds == 0) {
                    continue;
                }
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
