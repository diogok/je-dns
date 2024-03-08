const std = @import("std");
const os = std.os;

const log = std.log.scoped(.with_dns);

pub fn writeQuery(writer: anytype, name: []const u8) !void {
    const flags = Flags{
        .query_or_reply = .query,
        .opcode = .query,
        .recursion_desired = true,
        .recursion_available = true,
    };
    var header = Header{
        .ID = mkid(),
        .flags = @bitCast(flags),
        .number_of_questions = 1,
    };
    std.mem.byteSwapAllFields(Header, &header);
    var header_bytes = std.mem.toBytes(header);
    _ = try writer.write(header_bytes[0..12]);

    try writeName(writer, name);

    const question = QuestionSection{ .query_type = .A };
    var question_bytes = std.mem.toBytes(question);
    _ = try writer.write(question_bytes[0..]);
}

fn writeName(writer: anytype, name: []const u8) !void {
    var labels_iter = std.mem.splitScalar(u8, name, '.');
    while (labels_iter.next()) |label| {
        const len: u8 = @truncate(label.len);
        _ = try writer.write(&[_]u8{len});
        _ = try writer.write(label);
    }
    _ = try writer.write(&[_]u8{0});
}

pub fn read_response(allocator: std.mem.Allocator, reader: anytype) ![]Record {
    var buffer: [512]u8 = undefined;
    _ = try reader.read(&buffer);

    var header = std.mem.bytesToValue(Header, buffer[0..12]);
    std.mem.byteSwapAllFields(Header, &header);

    var pos: usize = 12;

    var i: usize = 0;
    while (i < header.number_of_questions) : (i += 1) {
        pos += getNameLen(buffer[pos..]);
        pos += @sizeOf(QuestionSection);
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

const Record = struct {
    allocator: std.mem.Allocator,
    resource: ResourceRecord,
    name: []const u8,
    data: []const u8,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.name);
        self.allocator.free(self.data);
    }
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

// each field type is supposed to be u16, but values fit in u8, by padding we avoid work re-aligning/swapping

const Header = packed struct {
    ID: u16,
    flags: u16 = 0,
    number_of_questions: u16 = 0,
    number_of_answers: u16 = 0,
    number_of_authority_resource_records: u16 = 0,
    number_of_additional_resource_records: u16 = 0,
};

const QueryType = enum(u8) {
    A = 1,
    AAAA = 28,
    CNAME = 5,
    NS = 2,
    PTR = 12,
    SRV = 33,
    TXT = 16,
};

const QuestionSection = packed struct {
    pad0: u8 = 0,
    query_type: QueryType,
    pad1: u8 = 0,
    query_class: u8 = 1,
};

const mDNSQuestionSection = packed struct {
    pad0: u8 = 0,
    query_type: QueryType,
    unicast: u1 = 1,
    pad1: u7 = 0,
    query_class: u8 = 1,
};

const ResourceRecord = packed struct {
    pad0: u8,
    resource_type: QueryType,
    pad1: u8,
    resource_class: u8,
    ttl: u32,
    length: u16,
};

fn mkid() u16 {
    var ts: os.timespec = undefined;
    os.clock_gettime(os.CLOCK.REALTIME, &ts) catch {};
    const UInt = std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(ts.tv_nsec)));
    const unsec: UInt = @bitCast(ts.tv_nsec);
    const id: u32 = @truncate(unsec + unsec / 65536);
    return @truncate(id);
}
