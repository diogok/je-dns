const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const data = @import("data.zig");

const log = std.log.scoped(.with_dns);

pub fn writeQuery(writer: anytype, question: data.Question) !u16 {
    const flags = data.Flags{
        .query_or_reply = .query,
        .opcode = .query,
        .recursion_desired = true,
        .recursion_available = true,
    };
    const header = data.Header{
        .ID = mkid(),
        .flags = flags,
        .number_of_questions = 1,
    };
    const message = data.Message{
        .header = header,
        .questions = &[_]data.Question{question},
        .records = &[_]data.Record{},
    };

    log.info("Query: {any}", .{message});
    try writeMessage(writer, message);

    return header.ID;
}

fn writeMessage(writer: anytype, message: data.Message) !void {
    // write header
    const header = message.header;
    try writer.writeInt(u16, header.ID, .big);
    try writer.writeInt(u16, @bitCast(header.flags), .big);
    try writer.writeInt(u16, header.number_of_questions, .big);
    try writer.writeInt(u16, header.number_of_answers, .big);
    try writer.writeInt(u16, header.number_of_authority_resource_records, .big);
    try writer.writeInt(u16, header.number_of_additional_resource_records, .big);

    // write questions
    for (message.questions) |question| {
        try writeName(writer, question.name);
        try writer.writeInt(u16, @intFromEnum(question.resource_type), .big);
        try writer.writeInt(u16, @intFromEnum(question.resource_class), .big);
    }

    // TODO: write records
}

test "Writing a query" {
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    const writer = stream.writer();

    _ = try writeQuery(writer, .{ .name = "example.com", .resource_type = .A });

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

pub fn readMessage(allocator: std.mem.Allocator, reader: anytype) !data.Message {
    // read all of the request, because we might need the all bytes for pointer/compressed labels
    var pos: usize = 0;
    var buffer: [512]u8 = undefined;
    _ = try reader.read(&buffer);

    const header_pack = Pack.init(buffer[0..12], 6); // To read the u16 as big endian

    var flag_bits = header_pack.get(1);
    if (builtin.cpu.arch.endian() == .little) {
        flag_bits = @bitReverse(flag_bits);
    }
    const flags: data.Flags = @bitCast(flag_bits);

    const header = data.Header{
        .ID = header_pack.get(0),
        .flags = flags,
        .number_of_questions = header_pack.get(2),
        .number_of_answers = header_pack.get(3),
        .number_of_authority_resource_records = header_pack.get(4),
        .number_of_additional_resource_records = header_pack.get(5),
    };
    pos += 12;
    log.info("Message header: {any}", .{header});

    // read questions
    var questions = std.ArrayList(data.Question).init(allocator);
    var i: usize = 0;
    while (i < header.number_of_questions) : (i += 1) {
        if (pos >= buffer.len) break;

        const name_len = getNameLen(buffer[pos..]);
        if (name_len == 0) break;

        const name = try readName(allocator, buffer[0..], buffer[pos..]);
        pos += name_len;

        const q_pack = Pack.init(buffer[pos .. pos + 4], 2);
        const r_type = q_pack.get(0);
        const r_class = q_pack.get(1);
        const question = data.Question{
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class),
        };
        pos += 4;

        try questions.append(question);
    }

    var records = std.ArrayList(data.Record).init(allocator);
    i = 0;
    while (i < header.number_of_answers) : (i += 1) {
        if (pos >= buffer.len) break;

        const name_len = getNameLen(buffer[pos..]);
        const name = try readName(allocator, buffer[0..], buffer[pos .. pos + name_len]);
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

        const extra = try allocator.alloc(u8, data_len);
        std.mem.copyForwards(u8, extra, buffer[pos .. pos + data_len]);
        pos += data_len;

        const record = data.Record{
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class),
            .ttl = ttl,
            .name = name,
            .data = extra,
        };
        try records.append(record);
    }

    return data.Message{
        .allocator = allocator,
        .header = header,
        .questions = try questions.toOwnedSlice(),
        .records = try records.toOwnedSlice(),
        .size = pos,
    };
}

test "Read reply" {
    const buffer = [_]u8{
        1, 0, // ID
        //129, 128, // flags: u16  = 10100001 10000000
        161, 128, // flags: u16  = 10100001 10000000
        0, 1, //  number of questions  = 1
        0, 2, // number of answers = 1
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

    const reply = try readMessage(testing.allocator, reader);
    defer reply.deinit();

    try testing.expectEqual(reply.header.ID, 256);
    //try testing.expectEqual(reply.header.flags.query_or_reply, .reply);
    //try testing.expectEqual(reply.header.flags.recursion_desired, true);
    //try testing.expectEqual(reply.header.flags.recursion_available, true);
    //try testing.expectEqual(reply.header.flags.response_code, .no_error);
    try testing.expectEqual(reply.header.number_of_questions, 1);
    try testing.expectEqual(reply.header.number_of_answers, 2);
    try testing.expectEqual(reply.questions.len, 1);
    try testing.expectEqual(reply.records.len, 2);

    try testing.expectEqualStrings(reply.questions[0].name, "example.com");
    try testing.expectEqual(reply.questions[0].resource_type, data.ResourceType.A);
    try testing.expectEqual(reply.questions[0].resource_class, data.ResourceClass.IN);

    try testing.expectEqualStrings(reply.records[0].name, "example.com");
    try testing.expectEqual(reply.records[0].resource_type, data.ResourceType.A);
    try testing.expectEqual(reply.records[0].resource_class, data.ResourceClass.IN);
    try testing.expectEqual(reply.records[0].ttl, 16777472);
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
            if (skip >= buffer.len) return 0;
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

test "Read name" {}

test "Read name with pointer" {}

fn mkid() u16 {
    var rnd = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
        break :blk seed;
    });
    return rnd.random().int(u16);
}
