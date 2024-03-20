const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const data = @import("data.zig");

const log = std.log.scoped(.with_dns);

pub fn writeMessage(writer: anytype, message: data.Message) !void {
    logMessage(message);

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

    var message = data.Message.initEmpty();
    message.questions = &[_]data.Question{
        .{
            .name = "example.com",
            .resource_type = .A,
        },
    };
    message.header.flags.recursion_available = true;
    message.header.flags.recursion_desired = true;
    message.header.number_of_questions = 1;

    try writeMessage(writer, message);

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
    var full_message = std.ArrayList(u8).init(allocator);
    defer full_message.deinit();

    var header_buffer: [12]u8 = undefined;
    _ = try reader.read(&header_buffer);
    try full_message.appendSlice(header_buffer[0..]);

    const header = readHeader(header_buffer[0..]);

    // read questions
    var questions = std.ArrayList(data.Question).init(allocator);
    errdefer {
        for (questions.items) |q| {
            allocator.free(q.name);
        }
        questions.deinit();
    }
    var i: usize = 0;
    while (i < header.number_of_questions) : (i += 1) {
        const name = try readName(allocator, &full_message, reader);
        errdefer allocator.free(name);

        var q_buffer: [4]u8 = undefined;
        _ = try reader.read(&q_buffer);
        try full_message.appendSlice(q_buffer[0..]);

        const q_pack = Pack.init(&q_buffer, 2);
        const r_type = q_pack.get(0);
        const r_class = q_pack.get(1);
        const question = data.Question{
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class),
        };

        try questions.append(question);
    }

    var records = std.ArrayList(data.Record).init(allocator);
    errdefer {
        for (records.items) |r| {
            allocator.free(r.name);
            allocator.free(r.data);
        }
        records.deinit();
    }
    i = 0;
    while (i < header.number_of_answers) : (i += 1) {
        const name = try readName(allocator, &full_message, reader);
        errdefer allocator.free(name);

        var r_buffer: [10]u8 = undefined;
        _ = try reader.read(&r_buffer);
        try full_message.appendSlice(r_buffer[0..]);

        const q_pack = Pack.init(r_buffer[0..4], 2);
        const r_type = q_pack.get(0);
        const r_class = q_pack.get(1);

        const ttl_pack = Pack2.init(r_buffer[4..8], 1);
        const ttl = ttl_pack.get(0);

        const l_pack = Pack.init(r_buffer[8..10], 1);
        const data_len = l_pack.get(0);

        const extra = try allocator.alloc(u8, data_len);
        errdefer allocator.free(extra);
        _ = try reader.read(extra);
        try full_message.appendSlice(extra);

        const record = data.Record{
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class),
            .ttl = ttl,
            .name = name,
            .data = extra,
        };
        try records.append(record);
    }

    const message = data.Message{
        .allocator = allocator,
        .header = header,
        .questions = try questions.toOwnedSlice(),
        .records = try records.toOwnedSlice(),
    };

    logMessage(message);
    return message;
}

fn readHeader(buffer: []u8) data.Header {
    const header_pack = Pack.init(buffer, 6); // To read the u16 as big endian

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

    return header;
}

test "Read reply" {
    const buffer = [_]u8{
        1, 0, // ID
        0b10100001, 0b10000000, // flags
        0, 1, //  number of questions  = 1
        0, 2, // number of answers = 1
        0, 0, 0, 0, //  other "number of"
        //  question
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // question type = A, class = IN
        // record
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', // first label of name
        0b11000000, 20, // last label of name is a pointer
        0, 1, 0, 1, // question type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        1, 2, 3, 4, // data
        // record
        3, 'w', 'w', 'w', // first label of name
        0b11000000, 29, // last label of name is a pointer recur
        //3, 'c', 'o', 'm', 0, // last label of name
        0, 1, 0, 1, // question type = A, class = IN
        1, 0, 1, 0, // ttl = 16777472
        0, 4, // length
        4, 3, 2, 1, // data
    };

    var stream = std.io.fixedBufferStream(&buffer);
    const reader = stream.reader();

    const reply = try readMessage(testing.allocator, reader);
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

    try testing.expectEqualStrings(reply.records[1].name, "www.example.com");
    try testing.expectEqual(reply.records[1].data[0], 4);
    try testing.expectEqual(reply.records[1].data[1], 3);
    try testing.expectEqual(reply.records[1].data[2], 2);
    try testing.expectEqual(reply.records[1].data[3], 1);
}

fn readName(allocator: std.mem.Allocator, full_buffer: *std.ArrayList(u8), reader: anytype) ![]const u8 {
    var name_buffer = std.ArrayList(u8).init(allocator);
    defer name_buffer.deinit();

    var len = try reader.readByte();
    try full_buffer.append(len);
    while (len > 0) {
        if (len & 0b11000000 == 0b11000000) {
            //const ptr0 = len;
            const ptr1 = try reader.readByte();
            try full_buffer.append(ptr1);

            const start: usize = @intCast(ptr1);
            //const max = @min(full_buffer.items.len, start + 512);
            //const re_buffer = full_buffer.items[start..max];

            var fake = std.ArrayList(u8).init(allocator);
            defer fake.deinit();
            try fake.appendSlice(full_buffer.items);

            var stream = std.io.fixedBufferStream(full_buffer.items);
            const re_reader = stream.reader();
            try re_reader.skipBytes(start, .{});

            const label = try readName(allocator, &fake, re_reader);
            defer allocator.free(label);

            try name_buffer.appendSlice(label);

            break;
        } else {
            const label = try allocator.alloc(u8, len);
            defer allocator.free(label);
            _ = try reader.read(label);

            try full_buffer.appendSlice(label);
            try name_buffer.appendSlice(label);

            len = try reader.readByte();
            try full_buffer.append(len);
            if (len > 0) {
                try name_buffer.append('.');
            }
        }
    }

    return try name_buffer.toOwnedSlice();
}

test "Read name" {}

test "Read name with pointer" {}

pub fn logMessage(msg: data.Message) void {
    log.info("┌──────", .{});
    log.info("│ ID: {d}", .{msg.header.ID});

    log.info("│ Type: {any}", .{msg.header.flags.query_or_reply});
    log.info("│ Opcode: {any}", .{msg.header.flags.opcode});
    log.info("│ Authoritative: {any}", .{msg.header.flags.authoritative_answer});
    log.info("│ Truncation: {any}", .{msg.header.flags.truncation});
    log.info("│ Recursion desired: {any}", .{msg.header.flags.recursion_desired});
    log.info("│ Recursion available: {any}", .{msg.header.flags.recursion_available});
    log.info("│ Response code: {any}", .{msg.header.flags.response_code});

    log.info("│ Questions: {d}", .{msg.header.number_of_questions});
    log.info("│ Answers: {d}", .{msg.header.number_of_answers});
    log.info("│ Authority records: {d}", .{msg.header.number_of_authority_resource_records});
    log.info("│ Additional records: {d}", .{msg.header.number_of_additional_resource_records});

    for (msg.questions, 0..) |q, i| {
        log.info("│ => Question {d}:", .{i});
        log.info("│ ==> Name: {s}", .{q.name});
        log.info("│ ==> Resource type: {any}", .{q.resource_type});
        log.info("│ ==> Resource class: {any}", .{q.resource_class});
    }

    for (msg.records, 0..) |r, i| {
        log.info("│ => Record {d}:", .{i});
        log.info("│ ==> Name: {s}", .{r.name});
        log.info("│ ==> Resource type: {any}", .{r.resource_type});
        log.info("│ ==> Resource class: {any}", .{r.resource_class});
        log.info("│ ==> TTL: {d}", .{r.ttl});
        log.info("│ ==> Data: {b}", .{r.data});
    }

    log.info("└──────", .{});
}
