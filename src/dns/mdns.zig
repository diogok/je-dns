//! This implements a mDNS DNS-SD service finder and responder.
//! It can anounce our service as well as find peers on the network.

const std = @import("std");
const testing = std.testing;

const data = @import("data.zig");
const net = @import("socket.zig");
const netif = @import("network_interface.zig");

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

    /// Service definition
    service: Service,
    /// Options for the service and socket
    options: mDNSServiceOptions,

    /// Internal buffers
    name_buffer: [data.NAME_MAX_SIZE]u8 = undefined,
    /// Internal buffers
    host_buffer: [data.NAME_MAX_SIZE]u8 = undefined,
    /// Internal buffers
    addresses_buffer: [32]std.net.Address = undefined,

    /// Creates a new instance of this struct.
    /// Should call deinit on the returned object once done.
    pub fn init(service: Service, options: mDNSServiceOptions) !@This() {
        const ipv4 = try net.Socket.init(data.mdns_ipv4_address, options.socket_options);
        try ipv4.bind();
        try ipv4.multicast();

        const ipv6 = try net.Socket.init(data.mdns_ipv6_address, options.socket_options);
        try ipv6.bind();
        try ipv6.multicast();

        return @This(){
            .sockets = .{ ipv4, ipv6 },
            .options = options,
            .service = service,
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
            .name = self.service.name,
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
    /// Might or might not return a peer
    /// Should not stop on null
    pub fn handle(self: *@This()) !?Peer {
        var buffer: [512]u8 = undefined;
        sockets: for (self.sockets) |socket| {
            receiving: while (true) {
                // catch timeout, try next socket
                const len = socket.receive(&buffer) catch continue :sockets;

                // parse the message
                // if it fails it is probably invalid message
                // so continue to try next message
                var message_reader = data.MessageReader.init(buffer[0..len]) catch continue :receiving;

                // handle the message
                if (try self.handleMessage(&message_reader, socket.getFamily())) |peer| {
                    // if the message contained a peer, return it
                    return peer;
                }
                // else just continue to next message or next socket
            }
        }
        return null;
    }

    /// This funtions check if this is a query or reply.
    fn handleMessage(self: *@This(), message_reader: *data.MessageReader, family: net.Family) !?Peer {
        switch (message_reader.header.flags.query_or_reply) {
            .reply => {
                return try self.handleReply(message_reader);
            },
            .query => {
                while (try message_reader.nextQuestion()) |q| {
                    if (std.mem.eql(u8, q.name, self.service.name)) {
                        try self.respond(family);
                    }
                }
                return null;
            },
        }
    }

    /// If it is a reply, check if this contains a Peer to our service and return it.
    /// If this reply is not about our service, returns null.
    fn handleReply(self: *@This(), message_reader: *data.MessageReader) !?Peer {
        var host: []const u8 = "";
        var port: u16 = 0;

        var peer: Peer = Peer{};

        var addresses_len: usize = 0;

        while (try message_reader.nextRecord()) |record| {
            switch (record.resource_type) {
                .PTR => { // PTR will have the a service instance
                    // confirm this is the service we want
                    if (std.mem.eql(u8, record.name, self.service.name)) {
                        std.mem.copyForwards(u8, &self.name_buffer, record.data.ptr);
                        peer.name = self.name_buffer[0..record.data.ptr.len];
                        peer.ttl_in_seconds = record.ttl;
                    }
                },
                .SRV => { // SRV will have a host and port
                    // confirm this is the service we found
                    if (std.mem.eql(u8, peer.name, record.name)) {
                        std.mem.copyForwards(u8, &self.host_buffer, record.data.srv.target);
                        host = self.host_buffer[0..record.data.srv.target.len];
                        port = record.data.srv.port;
                    }
                },
                .A, .AAAA => {
                    // get the IP of each host
                    if (std.mem.eql(u8, host, record.name)) {
                        var addr = record.data.ip;
                        // check if this is not our own address
                        if (!netif.isSelf(addr)) {
                            addr.setPort(port);
                            // add to this peer list of addresses
                            self.addresses_buffer[addresses_len] = addr;
                            addresses_len += 1;
                        }
                    }
                },
                else => {},
            }
        }

        peer.addresses = self.addresses_buffer[0..addresses_len];

        if (peer.addresses.len > 0) {
            return peer;
        } else {
            return null;
        }
    }

    /// Response with our service information.
    fn respond(self: *@This(), family: net.Family) !void {
        // Get our own hostname
        _ = std.c.gethostname(&self.host_buffer, HOST_NAME_MAX);
        const hostname = std.mem.span(@as([*c]u8, &self.host_buffer));

        // name of this service instance
        const full_service_name = std.fmt.bufPrint(
            &self.name_buffer,
            "{s}.{s}",
            .{
                hostname,
                self.service.name,
            },
        ) catch unreachable;

        // this host mdns name
        var target_buffer: [data.NAME_MAX_SIZE]u8 = undefined;
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

        // prepare basic header info
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
            .name = self.service.name,
            .resource_type = .PTR,
            .ttl = self.options.ttl_in_seconds,
            .data = .{
                .ptr = full_service_name,
            },
        };
        try record.writeTo(&stream);

        // Send the port and host
        record = data.Record{
            .name = full_service_name,
            .resource_type = .SRV,
            .ttl = self.options.ttl_in_seconds,
            .data = .{
                .srv = .{
                    .port = self.service.port,
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
                    .ttl = self.options.ttl_in_seconds,
                    .data = .{
                        .ip = addr.address,
                    },
                };
                try record.writeTo(&stream);
            } else if (family == .IPv6 and addr.family == .IPv6) {
                record = data.Record{
                    .name = target_host,
                    .resource_type = .AAAA,
                    .ttl = self.options.ttl_in_seconds,
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

/// This is another instance of our service in this network.
pub const Peer = struct {
    /// TTL in seconds of this DNS records.
    ttl_in_seconds: u32 = 0,
    /// addresses of this Peer.
    addresses: []const std.net.Address = &[_]std.net.Address{},
    /// full name of this instance.
    name: []const u8 = "",

    pub fn eql(self: @This(), other_peer: @This()) bool {
        return std.mem.eql(u8, self.name, other_peer.name);
    }
};
