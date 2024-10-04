//! Contains a DNS Server.

const std = @import("std");
const testing = std.testing;

const ns = @import("nameservers.zig");
const data = @import("data.zig");
const net = @import("socket.zig");

/// Options for mDNSServer.
pub const mDNServerOptions = struct {
    socket_options: net.Options = .{
        .timeout_in_millis = 100,
    },
};

/// mDNSServer, for receiving mDNS requests.
/// Main goal is to work with mDNS and DNS-SD.
pub const mDNSServer = struct {
    allocator: std.mem.Allocator,

    /// All bound sockets.
    /// One for IPv4 and one for IPv6.
    sockets: []*net.Socket,

    /// current socket in use
    curr: usize = 0,

    /// records
    records: []const data.Record,

    /// Creates a new DNSServer with given options.
    pub fn init(allocator: std.mem.Allocator, records: []const data.Record, options: mDNServerOptions) !@This() {

        // get the multicast addresses for mDNS
        const addresses = try ns.getNameservers(allocator, true);
        defer allocator.free(addresses);

        // alloc the needed sockets
        var i: usize = 0;
        const sockets = try allocator.alloc(*net.Socket, addresses.len);
        errdefer {
            for (sockets[0..i]) |socket| {
                allocator.destroy(socket);
            }
            allocator.free(sockets);
        }

        // bind and connect to all multicast addresses
        for (addresses) |address| {
            const socket = try allocator.create(net.Socket);
            socket.* = try net.Socket.init(address, options.socket_options);
            sockets[i] = socket;
            i += 1;
        }

        return @This(){
            .allocator = allocator,
            .sockets = sockets,
            .records = records,
        };
    }

    /// Clean-up and disconnect.
    pub fn deinit(self: *@This()) void {
        for (self.sockets) |socket| {
            socket.deinit();
            self.allocator.destroy(socket);
        }
        self.allocator.free(self.sockets);
    }

    /// Receive requests and send responses based on internal records.
    pub fn handle(self: *@This()) !void {
        while (try self.receive()) |msg| {
            for (msg.questions) |question| {
                if (question.resource_type != .PTR) {
                    continue;
                }
                const response = try self.makeResponse(
                    msg.header.ID,
                    question.name,
                );
                if (response) |r| {
                    try self.send(r);
                }
            }
        }
    }

    /// Receive next message to handle, or null if no message available yet.
    fn receive(self: *@This()) !?data.Message {
        // get current socket
        const socket = self.sockets[self.curr];
        // receive a message, ignore if it fails, probably a timeout or no response
        var stream = socket.receive() catch return null;
        // parse the message, if it fails it is probably invalid message so ignore
        const message = data.Message.read(self.allocator, &stream) catch return null;
        // move to next socket, or first if last
        self.curr += 1;
        if (self.curr == self.sockets.len) {
            self.curr = 0;
        }
        // return the message
        return message;
    }

    /// Send the message to all addresses.
    fn send(self: *@This(), message: data.Message) !void {
        for (self.sockets) |socket| {
            try message.writeTo(socket.stream());
            try socket.send();
        }
    }

    /// Builds the response Message based on internal records for requested name and resource type.
    fn makeResponse(self: *@This(), id: u16, question_name: []const u8) !?data.Message {
        // This is a request to list all services.
        if (std.ascii.eqlIgnoreCase(question_name, "_services._dns-sd._udp.local")) {
            var records = std.ArrayList(data.Record).init(self.allocator);
            defer records.deinit();

            for (self.records) |record| {
                if (record.resource_type == .PTR and std.ascii.endsWithIgnoreCase(record.name, "local")) {
                    try records.append(data.Record{
                        .name = question_name,
                        .resource_type = .PTR,
                        .resource_class = .IN,
                        .ttl = 6000,
                        .data = .{
                            .ptr = record.name,
                        },
                    });
                }
            }

            if (records.items.len == 0) {
                return null;
            }

            const final_records = try records.toOwnedSlice();

            return data.Message{
                .header = .{
                    .ID = id,
                    .flags = .{
                        .query_or_reply = .reply,
                        .authoritative_answer = true,
                    },
                    .number_of_answers = @truncate(final_records.len),
                },
                .records = final_records,
            };
        }

        var records = std.ArrayList(data.Record).init(self.allocator);
        defer records.deinit();
        var additional = std.ArrayList(data.Record).init(self.allocator);
        defer additional.deinit();

        std.debug.print("Query {s}\n", .{question_name});

        // here we try to find the specific records.
        for (self.records) |record| {
            std.debug.print("R {s}\n", .{record.name});
            // is this the exact record?
            if (std.mem.eql(u8, record.name, question_name)) {
                try records.append(record);
            }
            // is this a related record?
            if (std.ascii.endsWithIgnoreCase(record.name, question_name)) {}
            // is this related to the exact record?
            for (records.items) |_| {
                if (std.mem.eql(u8, record.name, question_name)) {}
            }
        }

        // If nothing found, return null.
        if (records.items.len == 0) {
            return null;
        }

        const final_records = try records.toOwnedSlice();
        const final_additional = try records.toOwnedSlice();
        return data.Message{
            .header = .{
                .ID = id,
                .flags = .{
                    .query_or_reply = .reply,
                    .authoritative_answer = true,
                },
                .number_of_answers = @truncate(final_records.len),
                .number_of_additional_resource_records = @truncate(final_additional.len),
            },
            .records = final_records,
            .additional_records = final_additional,
        };
    }
};
