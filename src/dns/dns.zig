const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const net = @import("socket.zig");

pub const Options = struct {
    socket_options: net.Options = .{
        .timeout_in_millis = 200,
    },
};

pub const DNClient = struct {
    allocator: std.mem.Allocator,
    options: Options,

    sockets: ?[]*net.Socket = null,
    stream: ?*net.Stream = null,
    iter: ?*MessageIterator(*net.Stream) = null,

    curr: usize = 0,

    state: enum {
        receive,
        iter,
        read,
        next_socket,
    } = .receive,

    pub fn init(allocator: std.mem.Allocator, options: Options) @This() {
        return @This(){
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn query(self: *@This(), name: []const u8, resource_type: ResourceType) !void {
        self.deinit();

        const local = isLocal(name);
        const message = Message{
            .header = .{
                .ID = mkid(),
                .flags = .{
                    .recursion_available = !local,
                    .recursion_desired = !local,
                },
                .number_of_questions = 1,
            },
            .questions = &[_]Question{
                .{
                    .name = name,
                    .resource_type = resource_type,
                },
            },
        };

        const servers = try getNameservers(self.allocator, name);
        defer self.allocator.free(servers);
        if (servers.len == 0) {
            return error.NoServerToQuery;
        }

        var sockets = try self.allocator.alloc(*net.Socket, servers.len);
        errdefer self.allocator.free(sockets);
        for (servers, 0..) |addr, i| {
            var socket = try net.Socket.init(addr, self.options.socket_options);
            try message.writeTo(socket.stream());
            try socket.send();
            sockets[i] = try self.allocator.create(net.Socket);
            sockets[i].* = socket;
        }
        self.sockets = sockets;
    }

    pub fn deinit(self: *@This()) void {
        if (self.sockets) |sockets| {
            for (sockets) |socket| {
                socket.deinit();
                self.allocator.destroy(socket);
            }
            self.allocator.free(sockets);
        }

        if (self.stream) |stream| {
            self.allocator.destroy(stream);
            self.stream = null;
        }
        if (self.iter) |iter| {
            self.allocator.destroy(iter);
            self.iter = null;
        }
        self.curr = 0;
        self.state = .receive;
    }

    pub fn next(self: *@This()) !?Record {
        var count: u8 = 0;
        next: while (true) : (count += 1) {
            if (count >= 9) {
                return null;
            }
            switch (self.state) {
                .receive => {
                    if (self.stream) |stream| {
                        self.allocator.destroy(stream);
                        self.stream = null;
                    }
                    // try to receive a packet form current socket
                    const stream = self.sockets.?[self.curr].receive() catch |err| {
                        switch (err) {
                            error.WouldBlock => {
                                // timeout, try next
                                self.state = .next_socket;
                                continue :next;
                            },
                            else => {
                                return err;
                            },
                        }
                    };
                    self.stream = try self.allocator.create(net.Stream);
                    self.stream.?.* = stream;
                    self.state = .iter;
                },
                .iter => {
                    if (self.iter) |iter| {
                        self.allocator.destroy(iter);
                        self.iter = null;
                    }
                    const iter = Message.streamIterator(self.allocator, self.stream.?);
                    self.iter = try self.allocator.create(MessageIterator(*net.Stream));
                    self.iter.?.* = iter;
                    self.state = .read;
                },
                .read => {
                    if (try self.iter.?.next()) |section| {
                        // if there a section to read
                        switch (section) {
                            .header => |header| {
                                if (header.flags.query_or_reply != .reply) {
                                    // only consider replies, skip queries
                                    self.state = .receive;
                                }
                                // go to next, state might be receive or read again
                            },
                            .question => |question| {
                                // discard question
                                question.deinit(self.allocator);
                                // read next
                            },
                            .record, .authority_record, .additional_record => |record| {
                                // return any found record
                                // state will still be read on next call
                                return record;
                            },
                        }
                    } else {
                        // there is no more section to read, receive packet on next socket
                        self.state = .next_socket;
                    }
                },
                .next_socket => {
                    self.curr += 1;
                    if (self.curr == self.sockets.?.len) {
                        // if read all sockets, got to begning;
                        self.curr = 0;
                    }
                    self.state = .receive;
                },
            }
        }
    }
    // no default return, each state and branch must return accordingly
};

pub const Message = struct {
    header: Header = Header{},
    questions: []const Question = &[_]Question{},
    records: []const Record = &[_]Record{},
    authority_records: []const Record = &[_]Record{},
    additional_records: []const Record = &[_]Record{},

    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
        var iter = @This().streamIterator(allocator, stream);

        var header: Header = .{};
        var questions = std.ArrayList(Question).init(allocator);
        var records = std.ArrayList(Record).init(allocator);
        var authority_records = std.ArrayList(Record).init(allocator);
        var additional_records = std.ArrayList(Record).init(allocator);
        errdefer {
            questions.deinit();
            records.deinit();
            authority_records.deinit();
            additional_records.deinit();
            for (questions.items) |q| {
                q.deinit(allocator);
            }
            for (records.items) |r| {
                r.deinit(allocator);
            }
            for (authority_records.items) |r| {
                r.deinit(allocator);
            }
            for (additional_records.items) |r| {
                r.deinit(allocator);
            }
        }

        while (try iter.next()) |section| {
            switch (section) {
                .header => |h| {
                    header = h;
                },
                .question => |q| {
                    try questions.append(q);
                },
                .record => |r| {
                    try records.append(r);
                },
                .authority_record => |r| {
                    try authority_records.append(r);
                },
                .additional_record => |r| {
                    try additional_records.append(r);
                },
            }
        }

        return @This(){
            .header = header,
            .questions = try questions.toOwnedSlice(),
            .records = try records.toOwnedSlice(),
            .authority_records = try authority_records.toOwnedSlice(),
            .additional_records = try additional_records.toOwnedSlice(),
        };
    }

    pub fn streamIterator(allocator: std.mem.Allocator, stream: anytype) MessageIterator(@TypeOf(stream)) {
        return MessageIterator(@TypeOf(stream)).init(allocator, stream);
    }

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

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
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
};

pub fn MessageIterator(StreamType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        stream: StreamType,

        header: ?Header = null,
        n: usize = 0,
        state: enum {
            header,
            questions,
            answers,
            authority_records,
            additional_records,
            done,
        } = .header,

        pub fn init(allocator: std.mem.Allocator, stream: StreamType) @This() {
            return .{ .allocator = allocator, .stream = stream };
        }

        pub fn next(self: *@This()) !?union(enum) {
            header: Header,
            question: Question,
            record: Record,
            authority_record: Record,
            additional_record: Record,
        } {
            switch (self.state) {
                .header => {
                    const header = try Header.read(self.stream);
                    self.header = header;
                    self.state = .questions;
                    return .{ .header = header };
                },
                .questions => {
                    if (self.n < self.header.?.number_of_questions) {
                        const question = try Question.read(self.allocator, self.stream);
                        self.n += 1;
                        return .{ .question = question };
                    } else {
                        self.n = 0;
                        self.state = .answers;
                        return self.next();
                    }
                },
                .answers => {
                    if (self.n < self.header.?.number_of_answers) {
                        const record = try Record.read(self.allocator, self.stream);
                        self.n += 1;
                        return .{ .record = record };
                    } else {
                        self.n = 0;
                        self.state = .authority_records;
                        return self.next();
                    }
                },
                .authority_records => {
                    if (self.n < self.header.?.number_of_authority_resource_records) {
                        const record = try Record.read(self.allocator, self.stream);
                        self.n += 1;
                        return .{ .authority_record = record };
                    } else {
                        self.n = 0;
                        self.state = .additional_records;
                        return self.next();
                    }
                },
                .additional_records => {
                    if (self.n < self.header.?.number_of_additional_resource_records) {
                        const record = try Record.read(self.allocator, self.stream);
                        self.n += 1;
                        return .{ .additional_record = record };
                    } else {
                        self.n = 0;
                        self.state = .done;
                        return self.next();
                    }
                },
                .done => {
                    return null;
                },
            }
        }
    };
}

pub const Header = packed struct {
    ID: u16 = 0,
    flags: Flags = Flags{},
    number_of_questions: u16 = 0,
    number_of_answers: u16 = 0,
    number_of_authority_resource_records: u16 = 0,
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
        try writer.writeInt(u16, @bitCast(self.flags), .big);
        try writer.writeInt(u16, self.number_of_questions, .big);
        try writer.writeInt(u16, self.number_of_answers, .big);
        try writer.writeInt(u16, self.number_of_authority_resource_records, .big);
        try writer.writeInt(u16, self.number_of_additional_resource_records, .big);
    }
};

pub const Flags = packed struct {
    query_or_reply: QueryOrReply = .query,
    opcode: Opcode = .query,
    authoritative_answer: bool = false,
    truncation: bool = false,
    recursion_desired: bool = false,
    recursion_available: bool = false,
    zero: u3 = 0,
    response_code: ReplyCode = .no_error,

    pub fn read(reader: anytype) !@This() {
        var flag_bits = try reader.readInt(u16, .big);
        if (builtin.cpu.arch.endian() == .little) {
            flag_bits = @bitReverse(flag_bits);
        }
        return @bitCast(flag_bits);
    }
};

pub const Question = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass = .IN,

    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
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

    pub fn writeTo(_: @This(), stream: anytype) !void {
        var writer = stream.writer();
        try writer.writeInt(u16, 0, .big);
        // TODO: writer for Resource data
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

fn readName(allocator: std.mem.Allocator, stream: anytype) ![]const u8 {
    var name_buffer = std.ArrayList(u8).init(allocator);
    defer name_buffer.deinit();

    var seekBackTo: u64 = 0;

    var reader = stream.reader();
    while (true) {
        const len = try reader.readByte();
        if (len == 0) {
            break;
        } else if (len >= 192) {
            const ptr0: u8 = len & 0b00111111;
            const ptr1: u8 = try reader.readByte();
            const ptr = (@as(u16, ptr0) << 8) + @as(u16, ptr1);
            if (seekBackTo == 0) {
                seekBackTo = try stream.getPos();
            }
            try stream.seekTo(ptr);
        } else {
            if (name_buffer.items.len > 0) try name_buffer.append('.');
            const label = try name_buffer.addManyAsSlice(len);
            _ = try reader.read(label);
        }
    }

    if (seekBackTo > 0) {
        try stream.seekTo(seekBackTo);
    }

    return try name_buffer.toOwnedSlice();
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

pub fn mkid() u16 {
    return @truncate(@as(u64, @bitCast(std.time.timestamp())));
}

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
        0, 2, // number of answers = 1
        0, 1, // number of authority answers = 1
        0, 1, // number of additional records = 1
        //  question
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // type = A, class = IN
        // record
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        0b11000000, 20, // last label of name is a pointer
        0, 1, 0, 1, // type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        1, 2, 3, 4, // data
        // record
        3, 'w', 'w', 'w', // first label of name
        0b11000000, 29, // last label of name is a pointer recur
        //3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        4, 3, 2, 1, // data
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
    defer reply.deinit(testing.allocator);

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

// Nameserver logic

pub fn getNameservers(allocator: std.mem.Allocator, name: []const u8) ![]std.net.Address {
    if (isLocal(name)) {
        return try getMulticast(allocator);
    } else {
        return try getDefaultNameservers(allocator);
    }
}

pub fn getDefaultNameservers(allocator: std.mem.Allocator) ![]std.net.Address {
    if (builtin.os.tag == .windows) {
        return try get_windows_dns_servers(allocator);
    } else {
        return try get_resolvconf_dns_servers(allocator);
    }
}

pub fn getMulticast(allocator: std.mem.Allocator) ![]std.net.Address {
    const addresses = try allocator.alloc(std.net.Address, 2);
    addresses[0] = try std.net.Address.parseIp("ff02::fb", 5353);
    addresses[1] = try std.net.Address.parseIp("224.0.0.251", 5353);
    return addresses;
}

// Resolv.conf

fn get_resolvconf_dns_servers(allocator: std.mem.Allocator) ![]std.net.Address {
    const resolvconf = try std.fs.openFileAbsolute("/etc/resolv.conf", .{});
    defer resolvconf.close();
    const reader = resolvconf.reader();
    return try parse_resolvconf(allocator, reader);
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

test "read resolv.conf" {
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

// Windows API and Structs for Nameservers

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

fn isLocal(address: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(address, ".local") or std.ascii.endsWithIgnoreCase(address, ".local.");
}
