//! Contains a DNS Client.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const net = @import("socket.zig");
const ns = @import("nameservers.zig");

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
    pub fn query(self: *@This(), name: []const u8, resource_type: ResourceType) !void {
        // .local domains are handled differently.
        const local = isLocal(name);

        // First, connect to all nameservers.
        try self.connect(local);

        // Prepare the query message
        const message = Message{
            .allocator = null,
            .header = .{
                .ID = mkid(), // Creates a new mesage ID
                .flags = .{
                    // For .local, you don't want recursion.
                    // It should resolve whithin your network.
                    .recursion_available = !local,
                    .recursion_desired = !local,
                },
                // Only one query
                .number_of_questions = 1,
            },
            .questions = &[_]Question{
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
    fn send(self: *@This(), message: Message) !void {
        for (self.sockets.?) |socket| {
            try message.writeTo(socket.stream());
            try socket.send();
        }
    }

    /// Reads the next (or first) response message.
    /// It will read from each server interleaved.
    pub fn next(self: *@This()) !?Message {
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
            const message = Message.read(self.allocator, &stream) catch continue;

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

/// This is a DNS message, used both for queries and responses.
pub const Message = struct {
    allocator: ?std.mem.Allocator = null,

    header: Header = Header{},
    questions: []const Question = &[_]Question{},
    records: []const Record = &[_]Record{},
    authority_records: []const Record = &[_]Record{},
    additional_records: []const Record = &[_]Record{},

    /// Read message from a Stream.
    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
        var questions = std.ArrayList(Question).init(allocator);
        var records = std.ArrayList(Record).init(allocator);
        var authority_records = std.ArrayList(Record).init(allocator);
        var additional_records = std.ArrayList(Record).init(allocator);

        errdefer {
            for (questions.items) |q| {
                q.deinit(allocator);
            }
            questions.deinit();
            for (records.items) |r| {
                r.deinit(allocator);
            }
            records.deinit();
            for (authority_records.items) |r| {
                r.deinit(allocator);
            }
            authority_records.deinit();
            for (additional_records.items) |r| {
                r.deinit(allocator);
            }
            additional_records.deinit();
        }

        const header = try Header.read(stream);

        var i: usize = 0;
        while (i < header.number_of_questions) : (i += 1) {
            const question = try Question.read(allocator, stream);
            try questions.append(question);
        }

        i = 0;
        while (i < header.number_of_answers) : (i += 1) {
            const record = try Record.read(allocator, stream);
            try records.append(record);
        }

        i = 0;
        while (i < header.number_of_authority_resource_records) : (i += 1) {
            const record = try Record.read(allocator, stream);
            try authority_records.append(record);
        }

        i = 0;
        while (i < header.number_of_additional_resource_records) : (i += 1) {
            const record = try Record.read(allocator, stream);
            try additional_records.append(record);
        }

        return @This(){
            .allocator = allocator,
            .header = header,
            .questions = try questions.toOwnedSlice(),
            .records = try records.toOwnedSlice(),
            .authority_records = try authority_records.toOwnedSlice(),
            .additional_records = try additional_records.toOwnedSlice(),
        };
    }

    /// Write message to a stream.
    pub fn writeTo(self: @This(), stream: anytype) !void {
        try self.header.writeTo(stream);
        for (self.questions) |question| {
            try question.writeTo(stream);
        }
        for (self.records) |record| {
            try record.writeTo(stream);
        }
        for (self.authority_records) |record| {
            try record.writeTo(stream);
        }
        for (self.additional_records) |record| {
            try record.writeTo(stream);
        }
    }

    /// Free used memory.
    pub fn deinit(self: @This()) void {
        if (self.allocator) |allocator| {
            for (self.questions) |q| {
                allocator.free(q.name);
            }
            allocator.free(self.questions);

            for (self.records) |r| {
                r.deinit(allocator);
            }
            allocator.free(self.records);

            for (self.authority_records) |r| {
                r.deinit(allocator);
            }
            allocator.free(self.authority_records);

            for (self.additional_records) |r| {
                r.deinit(allocator);
            }
            allocator.free(self.additional_records);
        }
    }
};

/// The first part of a DNS Message.
pub const Header = packed struct {
    /// Generated ID on the request,
    /// can be used to match a request and response.
    ID: u16 = 0,
    /// Flags have information about both query or answer.
    flags: Flags = Flags{},
    /// Number of questions, both in query and answer.
    number_of_questions: u16 = 0,
    /// Number of answers on responses.
    /// This is the common record response.
    number_of_answers: u16 = 0,
    /// Number of authority records on responses.
    /// This are responses if the server is the authority one.
    number_of_authority_resource_records: u16 = 0,
    /// Number of answers on responses.
    /// These are additional records, apart from the requested ones.
    number_of_additional_resource_records: u16 = 0,

    pub fn read(stream: anytype) !@This() {
        var reader = stream.reader();
        return @This(){
            .ID = try reader.readInt(u16, .big),
            .flags = try Flags.read(reader),
            .number_of_questions = try reader.readInt(u16, .big),
            .number_of_answers = try reader.readInt(u16, .big),
            .number_of_authority_resource_records = try reader.readInt(u16, .big),
            .number_of_additional_resource_records = try reader.readInt(u16, .big),
        };
    }

    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        try writer.writeInt(u16, self.ID, .big);

        try self.flags.writeTo(stream);

        try writer.writeInt(u16, self.number_of_questions, .big);
        try writer.writeInt(u16, self.number_of_answers, .big);
        try writer.writeInt(u16, self.number_of_authority_resource_records, .big);
        try writer.writeInt(u16, self.number_of_additional_resource_records, .big);
    }
};

/// Flags for a DNS message, for query and answer.
pub const Flags = packed struct {
    query_or_reply: QueryOrReply = .query,
    opcode: Opcode = .query,
    authoritative_answer: bool = false,
    truncation: bool = false,
    recursion_desired: bool = false,
    recursion_available: bool = false,
    padding: u3 = 0,
    response_code: ReplyCode = .no_error,

    pub fn read(reader: anytype) !@This() {
        var flag_bits = try reader.readInt(u16, .big);
        if (builtin.cpu.arch.endian() == .little) {
            flag_bits = @bitReverse(flag_bits);
        }
        return @bitCast(flag_bits);
    }

    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        var flag_bits: u16 = @bitCast(self);
        if (builtin.cpu.arch.endian() == .little) {
            flag_bits = @bitReverse(flag_bits);
        }
        try writer.writeInt(u16, flag_bits, .big);
    }
};

/// Question for a resource type. Also returned on Answers.
pub const Question = struct {
    /// Name is usually the domain, but also any query object.
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass = .IN,

    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
        // There are special rules for reading a name.
        const name = try readName(allocator, stream);
        errdefer allocator.free(name);

        var reader = stream.reader();
        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);

        return @This(){
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class & 0b1),
        };
    }

    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        try writeName(writer, self.name);
        try writer.writeInt(u16, @intFromEnum(self.resource_type), .big);
        try writer.writeInt(u16, @intFromEnum(self.resource_class), .big);
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Record = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass,
    ttl: u32,
    data: RecordData,

    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
        const name = try readName(allocator, stream);
        errdefer allocator.free(name);

        var reader = stream.reader();
        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);
        const ttl = try reader.readInt(u32, .big);

        const resource_type: ResourceType = @enumFromInt(r_type);
        const resource_class: ResourceClass = @enumFromInt(r_class & 0b1);

        const extra = try RecordData.read(allocator, resource_type, stream);

        return @This(){
            .resource_type = resource_type,
            .resource_class = resource_class,
            .ttl = ttl,
            .name = name,
            .data = extra,
        };
    }

    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        try writeName(writer, self.name);
        try writer.writeInt(u16, @intFromEnum(self.resource_type), .big);
        try writer.writeInt(u16, @intFromEnum(self.resource_class), .big);
        try writer.writeInt(u32, self.ttl, .big);
        try self.data.writeTo(stream);
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.data.deinit(allocator);
    }
};

pub const RecordData = union(enum) {
    ip: std.net.Address,
    srv: struct {
        priority: u16,
        weight: u16,
        port: u16,
        target: []const u8,
    },
    txt: []const []const u8,
    ptr: []const u8,
    raw: []const u8,

    pub fn read(allocator: std.mem.Allocator, resource_type: ResourceType, stream: anytype) !@This() {
        var reader = stream.reader();

        const len = try reader.readInt(u16, .big);
        const pos = try stream.getPos();
        defer stream.seekTo(len + pos) catch unreachable;

        switch (resource_type) {
            .A => {
                var bytes: [4]u8 = undefined;
                _ = try reader.read(&bytes);
                return .{ .ip = std.net.Address.initIp4(bytes, 0) };
            },
            .AAAA => {
                var bytes: [16]u8 = undefined;
                _ = try reader.read(&bytes);
                return .{ .ip = std.net.Address.initIp6(bytes, 0, 0, 0) };
            },
            .PTR => {
                return .{ .ptr = try readName(allocator, stream) };
            },
            .SRV => {
                return .{
                    .srv = .{
                        .weight = try reader.readInt(u16, .big),
                        .priority = try reader.readInt(u16, .big),
                        .port = try reader.readInt(u16, .big),
                        .target = try readName(allocator, stream),
                    },
                };
            },
            .TXT => {
                var txts = std.ArrayList([]const u8).init(allocator);
                errdefer {
                    for (txts.items) |text| {
                        allocator.free(text);
                    }
                    txts.deinit();
                }

                // TODO: split
                var total: usize = 0;
                while (total < len) {
                    const txt_len = try reader.readByte();
                    const txt = try allocator.alloc(u8, txt_len);
                    errdefer allocator.free(txt);

                    _ = try reader.read(txt);
                    total += len + 1;

                    try txts.append(txt);
                }

                return .{ .txt = try txts.toOwnedSlice() };
            },
            else => {
                const bytes = try allocator.alloc(u8, len);
                _ = try reader.read(bytes);
                return .{ .raw = bytes };
            },
        }
    }

    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        switch (self) {
            .ip => {
                try writer.writeInt(u16, 0, .big);
            },
            .srv => {
                try writer.writeInt(u16, 0, .big);
            },
            .txt => {
                try writer.writeInt(u16, 0, .big);
            },
            .ptr => |ptr| {
                try writer.writeInt(u16, @truncate(ptr.len), .big);
                try writeName(writer, ptr);
            },
            .raw => |bytes| {
                try writer.writeInt(u16, @truncate(bytes.len), .big);
                _ = try writer.write(bytes);
            },
        }
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .ip => {},
            .srv => |srv| {
                allocator.free(srv.target);
            },
            .txt => |text| {
                for (text) |txt| {
                    allocator.free(txt);
                }
                allocator.free(text);
            },
            .ptr => |ptr| {
                allocator.free(ptr);
            },
            .raw => |bytes| {
                allocator.free(bytes);
            },
        }
    }
};

/// Read a name from a DNS message.
/// DNS names has a format that require havin access to the whole message.
/// Each section (.) is prefixed with the length of that section.
/// The end is byte '0'.
/// A section maybe a pointer to another section elsewhere.
fn readName(allocator: std.mem.Allocator, stream: anytype) ![]const u8 {
    var name_buffer = std.ArrayList(u8).init(allocator);
    defer name_buffer.deinit();

    var seekBackTo: u64 = 0;

    var reader = stream.reader();
    while (true) {
        const len = try reader.readByte();
        if (len == 0) { // if len is zero, there is no more data
            break;
        } else if (len >= 192) { // a length starting with 0b11 is a pointer
            const ptr0: u8 = len & 0b00111111; // remove the points bits to get the
            const ptr1: u8 = try reader.readByte(); // the following byte is part of the pointer
            // Join the two bytes to get the address of the rest of the name
            const ptr = (@as(u16, ptr0) << 8) + @as(u16, ptr1);
            // save current position
            if (seekBackTo == 0) {
                seekBackTo = try stream.getPos();
            }
            try stream.seekTo(ptr);
        } else {
            // If we already have a section, append a "."
            if (name_buffer.items.len > 0) try name_buffer.append('.');
            // read the sepecificed len
            const label = try name_buffer.addManyAsSlice(len);
            _ = try reader.read(label);
        }
    }

    if (seekBackTo > 0) {
        try stream.seekTo(seekBackTo);
    }

    return try name_buffer.toOwnedSlice();
}

/// Writes a name in the format of DNS names.
/// Each "section" (the parts excluding the ".") is written
/// as first a byte with the length them the actual data.
/// The last byte is a 0 indicating the end (no more section).
fn writeName(writer: anytype, name: []const u8) !void {
    var labels_iter = std.mem.splitScalar(u8, name, '.');
    while (labels_iter.next()) |label| {
        const len: u8 = @truncate(label.len);
        _ = try writer.writeByte(len);
        _ = try writer.write(label);
    }
    _ = try writer.writeByte(0);
}

test "Write a name" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try writeName(writer, "example.com");
    var written = stream.getWritten();
    try testing.expectEqualStrings("\x07example\x03com\x00", written);

    stream.reset();

    try writeName(writer, "www.example.com");
    written = stream.getWritten();
    try testing.expectEqualStrings("\x03www\x07example\x03com\x00", written);
}

pub const QueryOrReply = enum(u1) { query, reply };

pub const Opcode = enum(u4) {
    query = 0,
    iquery = 1,
    status = 2,
    _,
};

pub const ReplyCode = enum(u4) {
    no_error = 0,
    format_error = 1,
    server_fail = 2,
    non_existent_domain = 3,
    not_implemented = 4,
    refused = 5,
    domain_should_not_exist = 6,
    resource_record_should_not_exist = 7,
    not_authoritative = 8,
    not_in_zone = 9,
    _,
};

pub const ResourceType = enum(u16) {
    A = 1,
    NS = 2,
    CNAME = 5,
    SOA = 6,
    PTR = 12,
    MX = 15,
    TXT = 16,
    AAAA = 28,
    SRV = 33,

    AFSDB = 18,
    APL = 42,
    CAA = 257,
    CERT = 60,
    CDS = 37,
    CSYNC = 62,
    DHCID = 49,
    DLV = 32769,
    DNAME = 39,
    DNSKEY = 48,
    DS = 43,
    EUI48 = 108,
    EUI64 = 109,
    HINFO = 13,
    HIP = 55,
    HTTPS = 65,
    IPSECKEY = 45,
    KEY = 25,
    KX = 36,
    LOC = 29,
    NAPTR = 35,
    NSEC = 47,
    NSEC3 = 50,
    NSEC3PARAM = 51,
    OPENPGPKEY = 61,
    RP = 17,
    RRSIG = 46,
    SIG = 24,
    SMIMEA = 53,
    SSHFP = 44,
    SVCB = 64,
    TA = 32768,
    TKEY = 249,
    TLSA = 22,
    TSIG = 250,
    URI = 256,
    ZONEMD = 63,
    _,
};

pub const ResourceClass = enum(u16) {
    IN = 1,
    _,
};

test "Write a message" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var message = Message{};
    message.questions = &[_]Question{
        .{
            .name = "example.com",
            .resource_type = .A,
        },
    };
    message.header.flags.recursion_available = true;
    message.header.flags.recursion_desired = true;
    message.header.number_of_questions = 1;

    try message.writeTo(&stream);

    const written = stream.getWritten();
    const example_query = [_]u8{
        0, 0, // skip id because it is generated
        1, 128, // flags: u16  = 110000000
        0, 1, //  number of questions :u16 = 1
        0, 0, 0, 0, 0, 0, //  other "number of"
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // question type = A, class = IN
    };
    try testing.expectEqualSlices(u8, example_query[2..], written[2..]);
}

test "Read a message" {
    const buffer = [_]u8{
        1, 0, // ID
        0b10100001, 0b10000000, // flags
        0, 1, //  number of questions  = 1
        0, 2, // number of answers = 2
        0, 1, // number of authority answers = 1
        0, 1, // number of additional records = 1
        //  question
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // type = A, class = IN
        // record
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        0b11000000, 20, // last label of name is a pointer to above .com
        0, 1, 0, 1, // type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        1, 2, 3, 4, // data 1.2.3.4
        // another record
        3, 'w', 'w', 'w', // first label of name
        0b11000000, 29, // last label of name is a pointer recur to above record
        //3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        4, 3, 2, 1, // data 4.3.2.1
        // authority record
        3, 'w', 'w', '2', // first label of name
        0b11000000, 29, // last label of name is a pointer recur
        //3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        4, 3, 2, 1, // data
        // additional record
        3, 'w', 'w', '1', // first label of name
        0b11000000, 29, // last label of name is a pointer recur
        //3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        4, 3, 2, 1, // data
    };

    var stream = std.io.fixedBufferStream(buffer[0..]);

    const reply = try Message.read(testing.allocator, &stream);
    defer reply.deinit();

    try testing.expectEqual(reply.header.ID, 256);
    try testing.expectEqual(reply.header.flags.query_or_reply, .reply);
    try testing.expectEqual(reply.header.flags.recursion_desired, true);
    try testing.expectEqual(reply.header.flags.recursion_available, true);
    try testing.expectEqual(reply.header.flags.response_code, .no_error);
    try testing.expectEqual(reply.header.number_of_questions, 1);
    try testing.expectEqual(reply.header.number_of_answers, 2);
    try testing.expectEqual(reply.questions.len, 1);
    try testing.expectEqual(reply.records.len, 2);
    try testing.expectEqual(reply.authority_records.len, 1);
    try testing.expectEqual(reply.additional_records.len, 1);

    try testing.expectEqualStrings(reply.questions[0].name, "example.com");
    try testing.expectEqual(reply.questions[0].resource_type, ResourceType.A);
    try testing.expectEqual(reply.questions[0].resource_class, ResourceClass.IN);

    try testing.expectEqualStrings(reply.records[0].name, "example.com");
    try testing.expectEqual(reply.records[0].resource_type, ResourceType.A);
    try testing.expectEqual(reply.records[0].resource_class, ResourceClass.IN);
    try testing.expectEqual(reply.records[0].ttl, 16777472);

    const ip1234 = try std.net.Address.parseIp("1.2.3.4", 0);
    try testing.expect(reply.records[0].data.ip.eql(ip1234));

    try testing.expectEqualStrings(reply.records[1].name, "www.example.com");
    const ip4321 = try std.net.Address.parseIp("4.3.2.1", 0);
    try testing.expect(reply.records[1].data.ip.eql(ip4321));

    try testing.expectEqualStrings(reply.authority_records[0].name, "ww2.example.com");
    try testing.expectEqualStrings(reply.additional_records[0].name, "ww1.example.com");
}

/// Check if this is a .local address.
pub fn isLocal(address: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(address, ".local") or
        std.ascii.endsWithIgnoreCase(address, ".local.");
}

/// Create a ID for a DNS message.
pub fn mkid() u16 {
    return @truncate(@as(u64, @bitCast(std.time.timestamp())));
}
