//! Common data structures for DNS messages

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Max size of a DNS name, like a full host.
pub const NAME_MAX_SIZE = 253;

/// Size of a UDP packet.
pub const PACKET_SIZE = 512;

/// Stream fo an UDP packet.
const PacketStream = std.io.FixedBufferStream([]const u8);

/// An reader and iterator to read a DNS message from a UDP packet.
/// Headers are read on initialization.
/// You should read all the Questions, them all the records.
pub const MessageReader = struct {
    buffer: [PACKET_SIZE]u8 = undefined,
    stream: PacketStream = undefined,

    header: Header = Header{},

    q: usize = 0,
    r: usize = 0,

    /// Create the reader, expect the message bytes.
    pub fn init(bytes: []const u8) !@This() {
        var self = @This(){};
        self.stream = std.io.fixedBufferStream(bytes);
        self.header = try Header.read(&self.stream);
        if (self.header.flags.truncation) {
            return error.MessageTruncated;
        }
        return self;
    }

    /// Return the next(or frst) question from the message.
    /// Returns null when there are no more questions.
    pub fn nextQuestion(self: *@This()) !?Question {
        if (self.q < self.header.number_of_questions) {
            self.q += 1;
            return try Question.read(&self.buffer, &self.stream);
        } else {
            return null;
        }
    }

    /// Return the next(or frst) record from the message.
    /// Returns null when there are no more record.
    pub fn nextRecord(self: *@This()) !?Record {
        const max = self.header.number_of_answers + self.header.number_of_additional_resource_records + self.header.number_of_authority_resource_records;
        if (self.r < max) {
            self.r += 1;
            return try Record.read(&self.buffer, &self.stream);
        } else {
            return null;
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

    /// Read headers from a stream.
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

    /// Write headers to a stream.
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

test "read header" {
    const bytes = [_]u8{
        1, 0, // ID
        0b10100001, 0b10000000, // flags
        0, 1, //  number of questions  = 1
        0, 2, // number of answers = 2
        0, 1, // number of authority answers = 1
        0, 1, // number of additional records = 1
    };

    var stream = std.io.fixedBufferStream(bytes[0..]);

    const header = try Header.read(&stream);

    try testing.expectEqual(header.ID, 256);
    try testing.expectEqual(header.flags.query_or_reply, .reply);
    try testing.expectEqual(header.flags.recursion_desired, true);
    try testing.expectEqual(header.flags.recursion_available, true);
    try testing.expectEqual(header.flags.response_code, .no_error);
    try testing.expectEqual(header.number_of_questions, 1);
    try testing.expectEqual(header.number_of_answers, 2);
}

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

    /// Read flags from a reader.
    pub fn read(reader: anytype) !@This() {
        var flag_bits = try reader.readInt(u16, .big);
        if (builtin.cpu.arch.endian() == .little) {
            flag_bits = @bitReverse(flag_bits);
        }
        return @bitCast(flag_bits);
    }

    /// Write flags to a stream.
    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        var flag_bits: u16 = @bitCast(self);
        if (builtin.cpu.arch.endian() == .little) {
            flag_bits = @bitReverse(flag_bits);
        }
        try writer.writeInt(u16, flag_bits, .big);
    }
};

test "read flags" {
    const bytes = [_]u8{
        0b10100001, 0b10000000, // flags
    };

    var stream = std.io.fixedBufferStream(bytes[0..]);
    var reader = stream.reader();

    const flags = try Flags.read(&reader);

    try testing.expectEqual(flags.query_or_reply, .reply);
    try testing.expectEqual(flags.recursion_desired, true);
    try testing.expectEqual(flags.recursion_available, true);
    try testing.expectEqual(flags.response_code, .no_error);
}

/// Question for a resource type. Sometimes also returned on Answers.
pub const Question = struct {
    /// Name is usually the domain, but also any query object.
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass = .IN,

    /// Read question from stream.
    pub fn read(buffer: []u8, stream: anytype) !@This() {
        // There are special rules for reading a name.
        const name = try readNameBuffer(buffer, stream);

        var reader = stream.reader();
        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);

        return @This(){
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class & 0b1),
        };
    }

    /// Write the Question to a stream.
    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        try writeName(writer, self.name);
        try writer.writeInt(u16, @intFromEnum(self.resource_type), .big);
        try writer.writeInt(u16, @intFromEnum(self.resource_class), .big);
    }
};

/// The information about a DNS Record
pub const Record = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass = .IN,
    /// Expiration in econds
    ttl: u32 = 0,
    data: RecordData,

    /// Read resource from stream.
    pub fn read(buffer: []u8, stream: anytype) !@This() {
        std.debug.assert(buffer.len > NAME_MAX_SIZE);

        const name = try readNameBuffer(buffer[0..NAME_MAX_SIZE], stream);

        var reader = stream.reader();
        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);
        const ttl = try reader.readInt(u32, .big);

        const resource_type: ResourceType = @enumFromInt(r_type);
        const resource_class: ResourceClass = @enumFromInt(r_class & 0b1);

        const record_data = try RecordData.read(buffer[NAME_MAX_SIZE..], resource_type, stream);

        return @This(){
            .resource_type = resource_type,
            .resource_class = resource_class,
            .ttl = ttl,
            .name = name,
            .data = record_data,
        };
    }

    /// Write resource to stream.
    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        try writeName(writer, self.name);
        try writer.writeInt(u16, @intFromEnum(self.resource_type), .big);
        try writer.writeInt(u16, @intFromEnum(self.resource_class), .big);
        try writer.writeInt(u32, self.ttl, .big);
        try self.data.writeTo(stream);
    }
};

/// Details of RecordData for TXT type.
pub const TXTIter = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.pos >= self.data.len) {
            return null;
        }
        const txt_len = self.data[self.pos];
        self.pos += 1;
        defer self.pos += txt_len;
        return self.data[self.pos .. self.pos + txt_len];
    }

    pub fn toBytes(buffer: []u8, txt: []const []const u8) []const u8 {
        var pos: usize = 0;
        for (txt) |t| {
            buffer[pos] = @truncate(t.len);
            pos += 1;
            std.mem.copyForwards(u8, buffer[pos..], t);
            pos += t.len;
        }
        return buffer[0..pos];
    }

    pub fn calcSize(txt: []const []const u8) usize {
        var pos: usize = 0;
        for (txt) |t| {
            pos += t.len + 1;
        }
    }
};

/// Details of RecordData for SRV type.
pub const SRV = struct {
    priority: u16,
    weight: u16,
    port: u16,
    target: []const u8,
};

/// The data that a Record hold,
/// depends on the resource class.
pub const RecordData = union(enum) {
    /// IPv4 or IPv6 address, for records like A or AAAA.
    ip: std.net.Address,
    /// Services information
    srv: SRV,
    /// For TXT records, a list of strings
    txt: []const u8,
    /// For PTR, likely a new domain, used in dns-sd for example.
    /// Works like a domain name
    ptr: []const u8,
    /// For other types, cotains the raw uninterpreted data.
    raw: []const u8,

    /// Read the record data from stream, need to know the resource type.
    pub fn read(buffer: []u8, resource_type: ResourceType, stream: anytype) !@This() {
        var reader = stream.reader();

        // Make sure we leave the stream at the end of the data.
        const data_len = try reader.readInt(u16, .big);
        const pos = try stream.getPos();
        defer stream.seekTo(data_len + pos) catch unreachable;

        const len = @min(data_len, buffer.len); // questionable...
        std.debug.assert(buffer.len >= len);

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
                return .{ .ptr = try readNameBuffer(buffer, stream) };
            },
            .SRV => {
                return .{
                    .srv = SRV{
                        .weight = try reader.readInt(u16, .big),
                        .priority = try reader.readInt(u16, .big),
                        .port = try reader.readInt(u16, .big),
                        .target = try readNameBuffer(buffer, stream),
                    },
                };
            },
            .TXT => {
                const data = buffer[0..len];
                _ = try reader.read(data);
                return .{ .txt = data };
            },
            else => {
                const data = buffer[0..len];
                _ = try reader.read(data);
                return .{ .raw = data };
            },
        }
    }

    /// Write the resource data to a stream.
    pub fn writeTo(self: @This(), stream: anytype) !void {
        var writer = stream.writer();
        switch (self) {
            .ip => |address| {
                switch (address.any.family) {
                    std.posix.AF.INET => {
                        try writer.writeInt(u16, 4, .big);
                        try writer.writeInt(u32, std.mem.nativeToBig(u32, address.in.sa.addr), .big);
                    },
                    std.posix.AF.INET6 => {
                        try writer.writeInt(u16, 16, .big);
                        for (address.in6.sa.addr) |byte| {
                            try writer.writeInt(u8, byte, .big);
                        }
                    },
                    else => {
                        unreachable;
                    },
                }
            },
            .srv => |srv| {
                try writer.writeInt(u16, @truncate(srv.target.len + 2 + 6), .big);
                try writer.writeInt(u16, srv.weight, .big);
                try writer.writeInt(u16, srv.priority, .big);
                try writer.writeInt(u16, srv.port, .big);
                try writeName(writer, srv.target);
            },
            .ptr => |ptr| {
                try writer.writeInt(u16, @truncate(ptr.len + 2), .big);
                try writeName(writer, ptr);
            },
            .raw, .txt => |bytes| {
                try writer.writeInt(u16, @truncate(bytes.len), .big);
                _ = try writer.write(bytes);
            },
        }
    }
};

test "write an ipv4" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const data = RecordData{
        .ip = std.net.Address.initIp4(
            [4]u8{ 127, 0, 0, 1 },
            0,
        ),
    };

    try data.writeTo(&stream);

    const written = stream.getWritten();
    const expected = [_]u8{
        0, 4, // length of data
        127, 0, 0, 1, // ip
    };
    try testing.expectEqualSlices(u8, expected[0..], written[0..]);
}

test "write an ipv6" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const data = RecordData{
        .ip = try std.net.Address.parseIp6(
            "ff::01",
            0,
        ),
    };

    try data.writeTo(&stream);

    const written = stream.getWritten();
    const expected = [_]u8{
        0, 16, // length of data
        0, 0xff,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 1, // ip
    };
    try testing.expectEqualSlices(u8, expected[0..], written[0..]);
}

test "write an ptr" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const data = RecordData{ .ptr = "abcdef" };

    try data.writeTo(&stream);

    const written = stream.getWritten();
    const expected = [_]u8{
        0, 8, // length of data (6 letters + name overhead)
        6, // name len
        97, 98, 99, 100, 101, 102, // ptr
        0,
    };
    try testing.expectEqualSlices(u8, expected[0..], written[0..]);
}

test "write an srv" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    const data = RecordData{
        .srv = .{
            .weight = 8,
            .priority = 1,
            .port = 80,
            .target = "hostname.local",
        },
    };

    try data.writeTo(&stream);

    const written = stream.getWritten();
    const expected = [_]u8{
        0, 22, // length of data (6 letters + name overhead)
        0, 8, // weigth
        0, 1, // priority
        0, 80, // port
        8, // label size
        'h', 'o', 's', 't', 'n', 'a', 'm', 'e', // label
        5, // label size
        'l', 'o', 'c', 'a', 'l', // label
        0, // end of name
    };
    try testing.expectEqualSlices(u8, expected[0..], written[0..]);
}

test "write txt" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var txt_buffer: [128]u8 = undefined;
    const data = RecordData{
        .txt = TXTIter.toBytes(
            &txt_buffer,
            &[_][]const u8{
                "hello=world",
                "foo=bar",
            },
        ),
    };

    try data.writeTo(&stream);

    const written = stream.getWritten();
    const expected = [_]u8{
        0, 20, // len of data
        11, // size of an entry
        'h', 'e', 'l', 'l', 'o', '=', 'w', 'o', 'r', 'l', 'd', // a label
        7, // size of an entry
        'f', 'o', 'o', '=', 'b', 'a', 'r', // another label
    };
    try testing.expectEqualSlices(u8, expected[0..], written[0..]);
}

test "read txt" {
    const data = [_]u8{
        0, 20, // len of data
        11, // size of an entry
        'h', 'e', 'l', 'l', 'o', '=', 'w', 'o', 'r', 'l', 'd', // a label
        7, // size of an entry
        'f', 'o', 'o', '=', 'b', 'a', 'r', // another label
    };
    var stream = std.io.fixedBufferStream(&data);

    var buffer: [512]u8 = undefined;
    const record = try RecordData.read(&buffer, .TXT, &stream);
    var txt_iter = TXTIter{ .data = record.txt };

    try testing.expectEqualStrings("hello=world", txt_iter.next().?);
    try testing.expectEqualStrings("foo=bar", txt_iter.next().?);
    try testing.expect(txt_iter.next() == null);
}

/// Read a name from a DNS message.
/// DNS names has a format that require havin access to the whole message.
/// Each section (.) is prefixed with the length of that section.
/// The end is byte '0'.
/// A section maybe a pointer to another section elsewhere.
fn readNameBuffer(name_buffer: []u8, stream: anytype) ![]const u8 {
    std.debug.assert(name_buffer.len >= NAME_MAX_SIZE);

    var name_len: usize = 0;

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
            if (name_len > 0) {
                name_buffer[name_len] = '.';
                name_len += 1;
            }
            // read the sepecificed len
            const increase = try reader.read(name_buffer[name_len .. name_len + len]);
            name_len += increase;
        }
    }

    if (seekBackTo > 0) {
        try stream.seekTo(seekBackTo);
    }

    return name_buffer[0..name_len];
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

/// If the message is a query (like question) or a reply (answer)
pub const QueryOrReply = enum(u1) { query, reply };

/// Type of message
pub const Opcode = enum(u4) {
    query = 0,
    iquery = 1,
    status = 2,
    _,
};

/// Possible reply code, used mainly to identify errors
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

/// Resource Type of a Record
pub const ResourceType = enum(u16) {
    /// Host Address
    A = 1,
    /// Authorittive nameserver
    NS = 2,
    /// Canonical name for an alias
    CNAME = 5,
    /// Start of a zone of Authority
    SOA = 6,
    /// Domain name pointer
    PTR = 12,
    /// Mail exchange
    MX = 15,
    /// text strings
    TXT = 16,
    /// IP6 Address
    AAAA = 28,
    /// Server Selection
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

/// Resource class of a Record
pub const ResourceClass = enum(u16) {
    /// Internet
    IN = 1,
    _,
};

test "Write a message" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var header = Header{};
    header.ID = 38749;
    header.flags.recursion_available = true;
    header.flags.recursion_desired = true;
    header.number_of_questions = 1;
    header.number_of_additional_resource_records = 2;
    try header.writeTo(&stream);

    const question = Question{
        .name = "example.com",
        .resource_type = .A,
    };
    try question.writeTo(&stream);

    const record0 = Record{
        .name = "example.com",
        .resource_type = .A,
        .resource_class = .IN,
        .ttl = 16777472,
        .data = RecordData{
            .ip = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 0),
        },
    };
    try record0.writeTo(&stream);
    const record1 = Record{
        .name = "example.com",
        .resource_type = .AAAA,
        .resource_class = .IN,
        .ttl = 16777472,
        .data = RecordData{
            .ip = std.net.Address.initIp6([16]u8{ 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0, 0, 0),
        },
    };
    try record1.writeTo(&stream);

    const written = stream.getWritten();
    const example_query = [_]u8{
        0b10010111, 0b1011101, // ID
        1, 128, // flags: u16  = 110000000
        0, 1, //  number of questions :u16 = 1
        0, 0, 0, 0, 0, 2, //  other "number of"
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // question type = A, class = IN
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // resource type = A, class = IN
        1, 0, 1, 0, // ttl
        0, 4, // length of data
        127, 0, 0, 1, // ip
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 28, 0, 1, // resource type = AAAA, class = IN
        1, 0, 1, 0, // ttl
        0, 16, // length of data
        0xff, 0, 0, 0, // ip
        0, 0, 0, 0, // ip
        0, 0, 0, 0, // ip
        0, 0, 0, 1, // ip
    };
    try testing.expectEqualSlices(u8, example_query[0..], written[0..]);
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

    var reply = try MessageReader.init(buffer[0..]);

    try testing.expectEqual(reply.header.ID, 256);
    try testing.expectEqual(reply.header.flags.query_or_reply, .reply);
    try testing.expectEqual(reply.header.flags.recursion_desired, true);
    try testing.expectEqual(reply.header.flags.recursion_available, true);
    try testing.expectEqual(reply.header.flags.response_code, .no_error);
    try testing.expectEqual(reply.header.number_of_questions, 1);
    try testing.expectEqual(reply.header.number_of_answers, 2);

    const question = (try reply.nextQuestion()).?;
    try testing.expectEqualStrings(question.name, "example.com");
    try testing.expectEqual(question.resource_type, ResourceType.A);
    try testing.expectEqual(question.resource_class, ResourceClass.IN);
    try testing.expect(try reply.nextQuestion() == null);

    const record0 = (try reply.nextRecord()).?;
    try testing.expectEqualStrings(record0.name, "example.com");
    try testing.expectEqual(record0.resource_type, ResourceType.A);
    try testing.expectEqual(record0.resource_class, ResourceClass.IN);
    try testing.expectEqual(record0.ttl, 16777472);

    const ip1234 = try std.net.Address.parseIp("1.2.3.4", 0);
    try testing.expect(record0.data.ip.eql(ip1234));

    const record1 = (try reply.nextRecord()).?;
    try testing.expectEqualStrings(record1.name, "www.example.com");
    const ip4321 = try std.net.Address.parseIp("4.3.2.1", 0);
    try testing.expect(record1.data.ip.eql(ip4321));

    const record2 = (try reply.nextRecord()).?;
    try testing.expectEqualStrings(record2.name, "ww2.example.com");

    const record3 = (try reply.nextRecord()).?;
    try testing.expectEqualStrings(record3.name, "ww1.example.com");

    try testing.expect(try reply.nextRecord() == null);
}

test "Write and read the same message" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    var header = Header{};
    header.ID = 38749;
    header.flags.recursion_available = true;
    header.flags.recursion_desired = true;
    header.number_of_questions = 1;
    header.number_of_additional_resource_records = 2;
    try header.writeTo(&stream);

    const question = Question{
        .name = "example.com",
        .resource_type = .A,
    };
    try question.writeTo(&stream);

    const record0 = Record{
        .name = "example.com",
        .resource_type = .A,
        .resource_class = .IN,
        .ttl = 16777472,
        .data = RecordData{
            .ip = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 0),
        },
    };
    try record0.writeTo(&stream);

    const record1 = Record{
        .name = "example.com",
        .resource_type = .AAAA,
        .resource_class = .IN,
        .ttl = 16777472,
        .data = RecordData{
            .ip = std.net.Address.initIp6([16]u8{ 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 0, 0, 0),
        },
    };
    try record1.writeTo(&stream);

    const written = stream.getWritten();

    var message_reader = try MessageReader.init(written);

    try testing.expectEqual(header, message_reader.header);

    const read_question = (try message_reader.nextQuestion()).?;
    try testing.expectEqualStrings(question.name, read_question.name);
    try testing.expectEqual(question.resource_class, read_question.resource_class);
    try testing.expectEqual(question.resource_type, read_question.resource_type);

    const read_record0 = (try message_reader.nextRecord()).?;
    try testing.expectEqualStrings(record0.name, read_record0.name);
    try testing.expectEqual(record0.ttl, read_record0.ttl);
    try testing.expectEqual(record0.resource_class, read_record0.resource_class);
    try testing.expectEqual(record0.resource_type, read_record0.resource_type);
    try testing.expect(record0.data.ip.eql(read_record0.data.ip));

    const read_record1 = (try message_reader.nextRecord()).?;
    try testing.expectEqualStrings(record1.name, read_record1.name);
    try testing.expectEqual(record1.ttl, read_record1.ttl);
    try testing.expectEqual(record1.resource_class, read_record1.resource_class);
    try testing.expectEqual(record1.resource_type, read_record1.resource_type);
    try testing.expect(record1.data.ip.eql(read_record1.data.ip));
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

/// Query to find all local network services.
pub const mdns_services_query = "_services._dns-sd._udp.local";
/// Resource Type for local network services.
pub const mdns_services_resource_type: ResourceType = .PTR;

/// Multicast IPv6 Address for mDNS.
pub const mdns_ipv6_address = std.net.Address.initIp6([16]u8{ 0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfb }, 5353, 0, 0);
/// Multicast IPv4 Address for mDNS.
pub const mdns_ipv4_address = std.net.Address.initIp4([4]u8{ 224, 0, 0, 251 }, 5353);
