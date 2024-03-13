const std = @import("std");
const testing = std.testing;
const os = std.os;
const builtin = @import("builtin");

const log = std.log.scoped(.with_dns);

pub const ResolveOptions = struct {};

pub fn query(allocator: std.mem.Allocator, name: []const u8, resource_type: ResourceType, options: ResolveOptions) !Reply {
    return queryDNS(allocator, name, resource_type, options);
}

pub fn queryDNS(allocator: std.mem.Allocator, name: []const u8, resource_type: ResourceType, _: ResolveOptions) !Reply {
    // TODO: enable override of dns server, timeout, other options
    const servers = try get_nameservers(allocator);
    defer allocator.free(servers);
    for (servers) |address| {
        log.info("Trying address: {any}", .{address});
        const sock = try os.socket(address.any.family, os.SOCK.DGRAM | os.SOCK.CLOEXEC, 0);
        defer os.close(sock);

        settimeout(sock) catch log.info("Unable to set timeout", .{});

        try os.connect(sock, &address.any, address.getOsSockLen());
        log.info("Connected to {any}", .{address});

        {
            var buffer: [512]u8 = undefined;
            var stream = std.io.fixedBufferStream(&buffer);
            const writer = stream.writer();

            try writeQuery(writer, name, resource_type);
            const req = stream.getWritten();
            _ = try os.send(sock, req[0..28], 0);
        }

        {
            var buffer: [512]u8 = undefined;
            _ = try os.recv(sock, &buffer, 0);
            var stream = std.io.fixedBufferStream(&buffer);
            const reader = stream.reader();

            const reply = try readReply(allocator, reader);
            if (reply.records.len > 0) {
                return reply;
            }
        }
    }

    return error.UnableToResolve;
}

pub fn writeQuery(writer: anytype, name: []const u8, resource_type: ResourceType) !void {
    // build header with flags
    const flags = Flags{
        .query_or_reply = .query,
        .opcode = .query,
        .recursion_desired = true,
        .recursion_available = true,
    };
    const header = Header{
        .ID = mkid(),
        .flags = flags,
        .number_of_questions = 1,
    };
    log.info("Query header: {any}", .{header});

    // write header
    try writer.writeInt(u16, header.ID, .big);
    try writer.writeInt(u16, @bitCast(header.flags), .big);
    try writer.writeInt(u16, header.number_of_questions, .big);
    try writer.writeInt(u16, header.number_of_answers, .big);
    try writer.writeInt(u16, header.number_of_authority_resource_records, .big);
    try writer.writeInt(u16, header.number_of_additional_resource_records, .big);

    // build question
    const question = Question{
        .name = name,
        .resource_type = resource_type,
        .resource_class = .IN,
    };
    log.info("Query question: {any}", .{question});

    // write question section
    try writeName(writer, question.name);
    try writer.writeInt(u16, @intFromEnum(question.resource_type), .big);
    try writer.writeInt(u16, @intFromEnum(question.resource_class), .big);

    log.info("Query done", .{});
}

test "Writing a query" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    try writeQuery(writer, "example.com", .A);

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

// To read the u16 as big endian
const Pack = std.PackedIntSliceEndian(u16, .big);
const Pack2 = std.PackedIntSliceEndian(u32, .big);

pub fn readReply(allocator: std.mem.Allocator, reader: anytype) !Reply {
    // read all of the request, because we might need the all bytes for pointer/compressed labels
    var pos: usize = 0;
    var buffer: [512]u8 = undefined;
    _ = try reader.read(&buffer);

    const header_pack = Pack.init(buffer[0..12], 6); // To read the u16 as big endian
    const header = Header{
        .ID = header_pack.get(0),
        .flags = @bitCast(header_pack.get(1)),
        .number_of_questions = header_pack.get(2),
        .number_of_answers = header_pack.get(3),
        .number_of_authority_resource_records = header_pack.get(4),
        .number_of_additional_resource_records = header_pack.get(5),
    };
    log.info("Reply header: {any}", .{header});
    pos += 12;

    // read questions
    var questions = std.ArrayList(Question).init(allocator);
    var i: usize = 0;
    while (i < header.number_of_questions) : (i += 1) {
        const name_len = getNameLen(buffer[pos..]);
        const name = try readName(allocator, buffer[0..], buffer[pos..]);
        pos += name_len;

        const q_pack = Pack.init(buffer[pos .. pos + 4], 2);
        const r_type = q_pack.get(0);
        const r_class = q_pack.get(1);
        const question = Question{
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class),
        };
        pos += 4;

        log.info("Reply question: {any}", .{question});
        try questions.append(question);
    }

    var records = std.ArrayList(Record).init(allocator);
    i = 0;
    while (i < header.number_of_answers) : (i += 1) {
        const name_len = getNameLen(buffer[pos..]);
        const name = try readName(allocator, buffer[0..], buffer[pos..]);
        pos += name_len;

        const q_pack = Pack.init(buffer[pos .. pos + 4], 2);
        const r_type = q_pack.get(0);
        const r_class = q_pack.get(1);
        pos += 4;

        const ttl_pack = Pack2.init(buffer[pos .. pos + 4], 1);
        const ttl = ttl_pack.get(0);
        pos += 4;

        const l_pack = Pack.init(buffer[pos .. pos + 4], 1);
        const data_len = l_pack.get(0);
        pos += 2;

        const data = try allocator.alloc(u8, data_len);
        std.mem.copyForwards(u8, data, buffer[pos .. pos + data_len]);
        pos += data_len;

        const record = Record{
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class),
            .ttl = ttl,
            .name = name,
            .data = data,
        };
        log.info("Reply record: {any}", .{record});
        try records.append(record);
    }

    return Reply{
        .allocator = allocator,
        .header = header,
        .questions = try questions.toOwnedSlice(),
        .records = try records.toOwnedSlice(),
    };
}

test "Read reply" {
    const buffer = [_]u8{
        1, 0, // ID
        1, 128, // flags: u16  = 110000000
        0, 1, //  number of questions  = 1
        0, 1, // number of answers = 1
        0, 0, 0, 0, //  other "number of"
        //  question
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // question type = A, class = IN
        // record
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // question type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        1, 2, 3, 4, // data
    };

    var stream = std.io.fixedBufferStream(&buffer);
    const reader = stream.reader();

    const reply = try readReply(testing.allocator, reader);
    defer reply.deinit();

    try testing.expectEqual(reply.header.ID, 256);
    try testing.expectEqual(reply.header.flags.recursion_desired, true);
    try testing.expectEqual(reply.header.number_of_questions, 1);
    try testing.expectEqual(reply.header.number_of_answers, 1);
    try testing.expectEqual(reply.questions.len, 1);
    try testing.expectEqual(reply.records.len, 1);

    try testing.expectEqualStrings(reply.questions[0].name, "example.com");
    try testing.expectEqual(reply.questions[0].resource_type, ResourceType.A);
    try testing.expectEqual(reply.questions[0].resource_class, ResourceClass.IN);

    try testing.expectEqualStrings(reply.records[0].name, "example.com");
    try testing.expectEqual(reply.records[0].resource_type, ResourceType.A);
    try testing.expectEqual(reply.records[0].resource_class, ResourceClass.IN);
    try testing.expectEqual(reply.records[0].ttl, 16777472); // TODO: read ttl
    try testing.expectEqual(reply.records[0].data.len, 4);

    try testing.expectEqual(reply.records[0].data[0], 1);
    try testing.expectEqual(reply.records[0].data[1], 2);
    try testing.expectEqual(reply.records[0].data[2], 3);
    try testing.expectEqual(reply.records[0].data[3], 4);
}

fn getNameLen(buffer: []u8) usize {
    var skip: usize = 1;
    var len = buffer[0];
    while (len > 0) : (skip += 1) {
        if (len == 192) {
            // this is a pointer to another memory region
            // used for compressed labels
            return skip + 1;
        } else {
            skip += len;
            len = buffer[skip];
        }
    }
    return skip;
}

test "Get name len" {}

test "Get name len with pointer" {}

fn readName(allocator: std.mem.Allocator, full_buffer: []u8, buffer: []u8) ![]const u8 {
    var arr = std.ArrayList(u8).init(allocator);

    var pos: usize = 0;

    var len = buffer[0];
    pos += 1;
    while (len > 0) {
        if (len == 192) {
            const ptr = buffer[pos];
            const ptr_name = try readName(allocator, full_buffer, full_buffer[ptr..]);
            defer allocator.free(ptr_name);
            try arr.appendSlice(ptr_name);
            break;
        }

        try arr.appendSlice(buffer[pos .. pos + len]);
        pos += len;

        len = buffer[pos];
        pos += 1;
        if (len > 0) {
            try arr.append('.');
        }
    }

    return arr.toOwnedSlice();
}

test "Read name len" {}

test "Read name len with pointer" {}

const Header = packed struct {
    ID: u16,
    flags: Flags,
    number_of_questions: u16 = 0,
    number_of_answers: u16 = 0,
    number_of_authority_resource_records: u16 = 0,
    number_of_additional_resource_records: u16 = 0,
};

const Flags = packed struct {
    query_or_reply: QueryOrReply = .query,
    opcode: Opcode = .query,
    authoritative_answer: bool = false,
    truncation: bool = false,
    recursion_desired: bool = false,
    recursion_available: bool = false,
    zero: u3 = 0,
    response_code: ReplyCode = .no_error,
};

const QueryOrReply = enum(u1) { query, reply };

const Opcode = enum(u4) {
    query = 0,
    iquery = 1,
    status = 2,
    _,
};

const ReplyCode = enum(u4) {
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

const ResourceType = enum(u16) {
    A = 1,
    AAAA = 28,
    CNAME = 5,
    NS = 2,
    PTR = 12,
    SRV = 33,
    TXT = 16,
};

const ResourceClass = enum(u16) {
    IN = 1,
};

const Question = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass,
};

const Record = struct {
    resource_type: ResourceType,
    resource_class: ResourceClass,
    ttl: u32,
    data: []const u8,
    name: []const u8,
};

const Reply = struct {
    allocator: std.mem.Allocator,

    header: Header,
    questions: []Question,
    records: []Record,

    pub fn deinit(self: @This()) void {
        for (self.questions) |q| {
            self.allocator.free(q.name);
        }
        self.allocator.free(self.questions);
        for (self.records) |r| {
            self.allocator.free(r.name);
            self.allocator.free(r.data);
        }
        self.allocator.free(self.records);
    }
};

fn mkid() u16 {
    var rnd = std.Random.DefaultPrng.init(0);
    return rnd.random().int(u16);
}
pub fn get_nameservers(allocator: std.mem.Allocator) ![]std.net.Address {
    if (builtin.os.tag == .windows) {
        return try get_windows_dns_servers(allocator);
    } else {
        const resolvconf = try std.fs.openFileAbsolute("/etc/resolv.conf", .{});
        defer resolvconf.close();
        const reader = resolvconf.reader();
        return try parse_resolvconf(allocator, reader);
    }
}

fn mdns_nameservers(allocator: std.mem.Allocator) ![]std.net.Address {
    const ips = [_][]const u8{ "ff02::fb", "224.0.0.251" };
    var addresses = std.ArrayList(std.net.Address).init(allocator);
    for (ips) |ip| {
        const address = std.net.Address.parseIp(ip, 5353) catch continue;
        try addresses.append(address);
    }
    return addresses.toOwnedSlice();
}

fn parse_resolvconf(allocator: std.mem.Allocator, reader: anytype) ![]std.net.Address {
    var addresses = std.ArrayList(std.net.Address).init(allocator);

    var buffer: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        if (line.len > 10 and std.mem.eql(u8, line[0..10], "nameserver")) {
            var pos: usize = 10;
            while (pos < line.len and std.ascii.isWhitespace(line[pos])) : (pos += 1) {}
            const start: usize = pos;
            while (pos < line.len and (std.ascii.isHex(line[pos]) or line[pos] == '.' or line[pos] == ':')) : (pos += 1) {}
            const address = std.net.Address.resolveIp(line[start..pos], 53) catch continue;
            try addresses.append(address);
        }
    }

    return addresses.toOwnedSlice();
}

test "nameservers" {
    const resolvconf =
        \\;a comment
        \\# another comment
        \\
        \\domain    example.com
        \\
        \\nameserver     127.0.0.53 # comment after
        \\nameserver ::ff
    ;
    var stream = std.io.fixedBufferStream(resolvconf);
    const reader = stream.reader();

    const addresses = try parse_resolvconf(testing.allocator, reader);
    defer testing.allocator.free(addresses);

    const ip4 = try std.net.Address.parseIp4("127.0.0.53", 53);
    const ip6 = try std.net.Address.parseIp6("::ff", 53);

    try testing.expectEqual(2, addresses.len);
    try testing.expect(addresses[0].eql(ip4));
    try testing.expect(addresses[1].eql(ip6));
}

fn get_windows_dns_servers(allocator: std.mem.Allocator) ![]std.net.Address {
    var addresses = std.ArrayList(std.net.Address).init(allocator);

    var info = std.mem.zeroInit(PFIXED_INFO, .{});
    var buf_len: u32 = @intCast(@sizeOf(PFIXED_INFO));
    _ = GetNetworkParams(&info, &buf_len);

    var maybe_server = info.CurrentDnsServer;
    while (maybe_server) |server| {
        var len: usize = 0;
        while (server.IpAddress.String[len] != 0) : (len += 1) {}
        const addr = server.IpAddress.String[0..len];
        const address = std.net.Address.parseIp(addr, 53) catch break;
        try addresses.append(address);
        maybe_server = server.Next;
    }

    return addresses.toOwnedSlice();
}

fn settimeout(fd: std.os.socket_t) !void {
    const micros: i32 = 1000000;
    if (micros > 0) {
        var timeout: std.os.timeval = undefined;
        timeout.tv_sec = @as(c_long, @intCast(@divTrunc(micros, 1000000)));
        timeout.tv_usec = @as(c_long, @intCast(@mod(micros, 1000000)));
        try std.os.setsockopt(
            fd,
            std.os.SOL.SOCKET,
            std.os.SO.RCVTIMEO,
            std.mem.toBytes(timeout)[0..],
        );
        try std.os.setsockopt(
            fd,
            std.os.SOL.SOCKET,
            std.os.SO.SNDTIMEO,
            std.mem.toBytes(timeout)[0..],
        );
    }
}

// Windows APIs
extern "iphlpapi" fn GetNetworkParams(pFixedInfo: ?*PFIXED_INFO, pOutBufLen: ?*u32) callconv(.C) u32;

const PFIXED_INFO = extern struct {
    HostName: [132]u8,
    DomainName: [132]u8,
    CurrentDnsServer: ?*IP_ADDR_STRING,
    DnsServerList: IP_ADDR_STRING,
    NodeType: u32,
    ScopeId: [260]u8,
    EnableRouting: u32,
    EnableProxy: u32,
    EnableDns: u32,
};

const IP_ADDR_STRING = extern struct {
    Next: ?*IP_ADDR_STRING,
    IpAddress: IP_ADDRESS_STRING,
    IpMask: IP_ADDRESS_STRING,
    Context: u32,
};

const IP_ADDRESS_STRING = extern struct {
    String: [16]u8,
};
