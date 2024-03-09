const std = @import("std");
const testing = std.testing;
const os = std.os;

const log = std.log.scoped(.with_dns);

pub fn writeQuery(writer: anytype, name: []const u8, query_type: QueryType) !void {
    const flags = Flags{
        .query_or_reply = .query,
        .opcode = .query,
        .recursion_desired = true,
        .recursion_available = true,
    };
    const header = Header{
        .ID = mkid(),
        .flags = @bitCast(flags),
        .number_of_questions = 1,
    };
    log.info("Q header: {any}", .{header});

    // write header
    try writer.writeInt(u16, header.ID, .big);
    try writer.writeInt(u16, header.flags, .big);
    try writer.writeInt(u16, header.number_of_questions, .big);
    try writer.writeInt(u16, header.number_of_answers, .big);
    try writer.writeInt(u16, header.number_of_authority_resource_records, .big);
    try writer.writeInt(u16, header.number_of_additional_resource_records, .big);

    // write question section
    try writeName(writer, name);
    try writer.writeInt(u16, @intFromEnum(query_type), .big);
    try writer.writeInt(u16, @intFromEnum(QueryClass.IN), .big);
    log.info("Q header: {any}", .{header});
}

test "Writing a query" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try writeQuery(&writer, "example.com", .A);

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
    var writer = stream.writer();

    try writeName(&writer, "example.com");
    var written = stream.getWritten();
    try testing.expectEqualStrings("\x07example\x03com\x00", written);

    stream.reset();

    try writeName(&writer, "www.example.com");
    written = stream.getWritten();
    try testing.expectEqualStrings("\x03www\x07example\x03com\x00", written);
}

pub fn read_response(allocator: std.mem.Allocator, reader: anytype) ![]Record {
    // read all of the request, because we might need the bytes for pointer labels
    var buffer: [512]u8 = undefined;
    _ = try reader.read(&buffer);

    // read header
    var header = std.mem.bytesToValue(Header, buffer[0..12]);
    std.mem.byteSwapAllFields(Header, &header);
    log.info("R header: {any}", .{header});

    var pos: usize = 12;

    // skip questions
    var i: usize = 0;
    while (i < header.number_of_questions) : (i += 1) {
        pos += getNameLen(buffer[pos..]);
        pos += 4; // skip question fields
    }

    var records = std.ArrayList(Record).init(allocator);

    i = 0;
    while (i < header.number_of_answers) : (i += 1) {
        const name_len = getNameLen(buffer[pos..]);
        const name = try readName(allocator, buffer[0..], buffer[pos..]);
        pos += name_len;

        var resource = std.mem.bytesToValue(ResourceRecord, buffer[pos .. pos + @sizeOf(ResourceRecord)]);
        std.mem.byteSwapAllFields(ResourceRecord, &resource);
        pos += @sizeOf(ResourceRecord);

        const data = try allocator.alloc(u8, resource.length);
        std.mem.copyForwards(u8, data, buffer[pos .. pos + data.len]);

        const rec = Record{
            .allocator = allocator,
            .resource = resource,
            .name = name,
            .data = data,
        };
        try records.append(rec);
    }

    return records.toOwnedSlice();
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
    response_code: ResponseCode = .no_error,
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

const ResponseCode = enum(u4) {
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

const QueryType = enum(u16) {
    A = 1,
    AAAA = 28,
    CNAME = 5,
    NS = 2,
    PTR = 12,
    SRV = 33,
    TXT = 16,
};

const QueryClass = enum(u16) {
    IN = 1,
};

const ResourceRecord = packed struct {
    resource_type: QueryType,
    resource_class: QueryClass,
    ttl: u32,
    length: u16,
};

const Record = struct {
    resource_type: QueryType,
    resource_class: QueryClass,
    ttl: u32,
    length: u16,
    data: []const u8,
    name: []const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.name);
    }
};

pub fn free_records(allocator: std.mem.Allocator, records: []Record) void {
    for (records) |record| {
        record.deinit(allocator);
    }
    allocator.free(records);
}

fn mkid() u16 {
    var ts: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.REALTIME, &ts) catch {};
    const UInt = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(ts.tv_nsec)));
    const unsec: UInt = @bitCast(ts.tv_nsec);
    const id: u32 = @truncate(unsec + unsec / 65536);
    return @truncate(id);
}
