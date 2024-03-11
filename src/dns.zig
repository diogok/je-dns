const std = @import("std");
const testing = std.testing;
const os = std.os;

const log = std.log.scoped(.with_dns);

pub fn writeQuery(writer: anytype, name: []const u8, resource_type: ResourceType) !void {
    // build header with flags
    const flags = Flags{
        .query_or_reply = .query,
        .opcode = .query,
        .recursion_desired = true,
        .recursion_available = true,
    };
    log.info("Query flags: {any}", .{flags});
    const header = Header{
        .ID = mkid(),
        .flags = @bitCast(flags),
        .number_of_questions = 1,
    };
    log.info("Query header: {any}", .{header});

    // write header
    try writer.writeInt(u16, header.ID, .big);
    try writer.writeInt(u16, header.flags, .big);
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

const Pack = std.PackedIntSliceEndian(u16, .big);

pub fn read_reply(allocator: std.mem.Allocator, reader: anytype) !Reply {
    // read all of the request, because we might need the bytes for pointer labels
    var pos: usize = 0;
    var buffer: [512]u8 = undefined;
    _ = try reader.read(&buffer);

    const header_pack = Pack.init(buffer[0..12], 6);
    const header = Header{
        .ID = header_pack.get(0),
        .flags = header_pack.get(1),
        .number_of_questions = header_pack.get(2),
        .number_of_answers = header_pack.get(3),
        .number_of_authority_resource_records = header_pack.get(4),
        .number_of_additional_resource_records = header_pack.get(5),
    };
    log.info("Reply header: {any}", .{header});
    const flags: Flags = @bitCast(header.flags);
    log.info("Reply flags: {any}", .{flags});

    pos += 12;

    var questions = std.ArrayList(Question).init(allocator);

    // read questions
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
        // TODO: read ttl : u32
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
            .ttl = 0,
            .name = name,
            .data = data,
        };
        log.info("Reply record: {any}", .{record});
        try records.append(record);
    }

    return Reply{
        .allocator = allocator,
        .header = header,
        .flags = flags,
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

    const reply = try read_reply(testing.allocator, reader);
    defer reply.deinit();

    try testing.expectEqual(reply.header.ID, 256);
    try testing.expectEqual(reply.flags.recursion_desired, true);
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
    //try testing.expectEqual(reply.records[0].ttl, 16777472); // TODO: read ttl
    try testing.expectEqual(reply.records[0].data.len, 4);

    try testing.expectEqual(reply.records[0].data[0], 1);
    try testing.expectEqual(reply.records[0].data[1], 2);
    try testing.expectEqual(reply.records[0].data[2], 3);
    try testing.expectEqual(reply.records[0].data[3], 4);
}

fn getNameLen(buffer: []u8) usize {
    var skip: usize = 0;

    var len = buffer[0];
    skip += 1;
    while (len > 0) {
        if (len == 192) {
            skip += 1;
            break;
        } else {
            skip += len;
            len = buffer[skip];
            skip += 1;
        }
    }

    return skip;
}

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

const Header = packed struct {
    ID: u16,
    flags: u16 = 0,
    number_of_questions: u16 = 0,
    number_of_answers: u16 = 0,
    number_of_authority_resource_records: u16 = 0,
    number_of_additional_resource_records: u16 = 0,
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
    flags: Flags,
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
    var ts: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.REALTIME, &ts) catch {};
    const UInt = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(ts.tv_nsec)));
    const unsec: UInt = @bitCast(ts.tv_nsec);
    const id: u32 = @truncate(unsec + unsec / 65536);
    return @truncate(id);
}
