const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const data = @import("data.zig");

const log = std.log.scoped(.with_dns);

pub fn writeMessage(writer: anytype, message: data.Message) !void {
    //logMessage(log.debug, message);

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

    var message = data.Message{};
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
    const questions = try readQuestions(allocator, header.number_of_questions, reader, &full_message);
    errdefer {
        for (questions) |q| {
            allocator.free(q.name);
        }
        allocator.free(questions);
    }

    const records = try readRecords(allocator, header.number_of_answers, reader, &full_message);
    errdefer {
        for (records) |r| {
            r.deinit(allocator);
        }
        allocator.free(records);
    }

    const authority_records = try readRecords(allocator, header.number_of_authority_resource_records, reader, &full_message);
    errdefer {
        for (authority_records) |r| {
            r.deinit(allocator);
        }
        allocator.free(authority_records);
    }

    const additional_records = try readRecords(allocator, header.number_of_additional_resource_records, reader, &full_message);
    errdefer {
        for (additional_records) |r| {
            r.deinit(allocator);
        }
        allocator.free(additional_records);
    }

    const message = data.Message{
        .header = header,
        .questions = questions,
        .records = records,
        .authority_records = authority_records,
        .additional_records = additional_records,
    };

    //logMessage(log.debug, message);
    return message;
}

test "Read reply" {
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

    var stream = std.io.fixedBufferStream(&buffer);
    const reader = stream.reader();

    const reply = try readMessage(testing.allocator, reader);
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
    try testing.expectEqual(reply.questions[0].resource_type, data.ResourceType.A);
    try testing.expectEqual(reply.questions[0].resource_class, data.ResourceClass.IN);

    try testing.expectEqualStrings(reply.records[0].name, "example.com");
    try testing.expectEqual(reply.records[0].resource_type, data.ResourceType.A);
    try testing.expectEqual(reply.records[0].resource_class, data.ResourceClass.IN);
    try testing.expectEqual(reply.records[0].ttl, 16777472);

    const ip1234 = try std.net.Address.parseIp("1.2.3.4", 0);
    try testing.expect(reply.records[0].data.ip.eql(ip1234));

    try testing.expectEqualStrings(reply.records[1].name, "www.example.com");
    const ip4321 = try std.net.Address.parseIp("4.3.2.1", 0);
    try testing.expect(reply.records[1].data.ip.eql(ip4321));

    try testing.expectEqualStrings(reply.authority_records[0].name, "ww2.example.com");
    try testing.expectEqualStrings(reply.additional_records[0].name, "ww1.example.com");
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
fn readQuestions(allocator: std.mem.Allocator, n: usize, reader: anytype, full_message: *std.ArrayList(u8)) ![]data.Question {
    var i: usize = 0;

    var questions = try allocator.alloc(data.Question, n);
    errdefer {
        for (questions[0..i]) |q| {
            allocator.free(q.name);
        }
        allocator.free(questions);
    }

    while (i < n) : (i += 1) {
        const name = try readName(allocator, reader, full_message);
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

        questions[i] = question;
    }
    return questions;
}

fn readRecords(allocator: std.mem.Allocator, n: usize, reader: anytype, full_message: *std.ArrayList(u8)) ![]data.Record {
    var i: usize = 0;

    var records = try allocator.alloc(data.Record, n);
    errdefer {
        for (records[0..i]) |r| {
            r.deinit(allocator);
        }
        allocator.free(records);
    }

    while (i < n) : (i += 1) {
        const name = try readName(allocator, reader, full_message);
        errdefer allocator.free(name);

        var r_buffer: [10]u8 = undefined;
        _ = try reader.read(&r_buffer);
        try full_message.appendSlice(r_buffer[0..]);

        const q_pack = Pack.init(r_buffer[0..4], 2);
        const r_type = q_pack.get(0);
        const r_class = q_pack.get(1);

        const resource_type: data.ResourceType = @enumFromInt(r_type);
        const resource_class: data.ResourceClass = @enumFromInt(r_class & 0b1);

        const ttl_pack = Pack2.init(r_buffer[4..8], 1);
        const ttl = ttl_pack.get(0);

        const l_pack = Pack.init(r_buffer[8..10], 1);
        const data_len = l_pack.get(0);

        const before = full_message.items.len;
        const extra = try readRecordData(allocator, resource_type, data_len, reader, full_message);
        errdefer extra.deinit(allocator);
        const after = full_message.items.len;
        const missing = data_len - (after - before);

        if (missing > 0) {
            const missing_buffer = try allocator.alloc(u8, missing);
            defer allocator.free(missing_buffer);
            _ = try reader.read(missing_buffer);
            try full_message.appendSlice(missing_buffer);
        }

        const record = data.Record{
            .resource_type = resource_type,
            .resource_class = resource_class,
            .ttl = ttl,
            .name = name,
            .data = extra,
        };

        records[i] = record;
    }

    return records;
}

fn readRecordData(allocator: std.mem.Allocator, resource_type: data.ResourceType, n: usize, reader: anytype, full_message: *std.ArrayList(u8)) !data.RecordData {
    switch (resource_type) {
        .A => {
            var bytes: [4]u8 = undefined;
            _ = try reader.read(&bytes);
            try full_message.appendSlice(bytes[0..]);
            const addr = std.net.Address.initIp4(bytes, 0);
            return .{ .ip = addr };
        },
        .AAAA => {
            var bytes: [16]u8 = undefined;
            _ = try reader.read(&bytes);
            try full_message.appendSlice(bytes[0..]);
            const addr = std.net.Address.initIp6(bytes, 0, 0, 0);
            return .{ .ip = addr };
        },
        .PTR => {
            return .{ .raw = try readName(allocator, reader, full_message) };
        },
        .SRV => {
            var i_buffer: [6]u8 = undefined;
            _ = try reader.read(&i_buffer);
            try full_message.appendSlice(i_buffer[0..]);

            const i_pack = Pack.init(&i_buffer, 3);
            const weight = i_pack.get(0);
            const priority = i_pack.get(1);
            const port = i_pack.get(2);

            const target = try readName(allocator, reader, full_message);

            return .{
                .srv = .{
                    .weight = weight,
                    .priority = priority,
                    .port = port,
                    .target = target,
                },
            };
        },
        .TXT => {
            var texts = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (texts.items) |text| {
                    allocator.free(text);
                }
                texts.deinit();
            }

            var total: usize = 0;
            while (total < n) {
                const len = try reader.readByte();
                try full_message.append(len);
                total += 1;

                const text = try allocator.alloc(u8, len);
                errdefer allocator.free(text);

                _ = try reader.read(text);
                try full_message.appendSlice(text);
                total += len;

                try texts.append(text);
            }
            return .{ .txt = try texts.toOwnedSlice() };
        },
        else => {
            var bytes = try allocator.alloc(u8, n);
            errdefer allocator.free(bytes);

            _ = try reader.read(bytes);
            try full_message.appendSlice(bytes[0..]);

            return .{ .raw = bytes };
        },
    }
}

fn readName(allocator: std.mem.Allocator, reader: anytype, full_message: *std.ArrayList(u8)) ![]const u8 {
    var name_buffer = std.ArrayList(u8).init(allocator);
    defer name_buffer.deinit();

    var len = try reader.readByte();
    try full_message.append(len);
    while (len > 0) {
        if (len >= 192) {
            const ptr0 = len & 0b00111111;
            const ptr1 = try reader.readByte();
            try full_message.append(ptr1);

            var ptrs = [_]u8{ ptr0, ptr1 };
            const p_pack = Pack.init(&ptrs, 1);
            const ptr = p_pack.get(0);

            const start: usize = @intCast(ptr);

            var fake = std.ArrayList(u8).init(allocator);
            defer fake.deinit();
            try fake.appendSlice(full_message.items);

            var stream = std.io.fixedBufferStream(full_message.items);
            const re_reader = stream.reader();
            try re_reader.skipBytes(start, .{});

            const label = try readName(allocator, re_reader, &fake);
            defer allocator.free(label);

            try name_buffer.appendSlice(label);

            break;
        } else {
            const label = try allocator.alloc(u8, len);
            defer allocator.free(label);
            _ = try reader.read(label);

            try full_message.appendSlice(label);
            try name_buffer.appendSlice(label);

            len = try reader.readByte();
            try full_message.append(len);
            if (len > 0) {
                try name_buffer.append('.');
            }
        }
    }

    return try name_buffer.toOwnedSlice();
}

test "Read name" {}

test "Read name with pointer" {}

pub fn logMessage(logfn: anytype, msg: data.Message) void {
    logfn("┌──────", .{});
    logfn("│ ID: {d}", .{msg.header.ID});

    logfn("│ Type: {any}", .{msg.header.flags.query_or_reply});
    logfn("│ Opcode: {any}", .{msg.header.flags.opcode});
    logfn("│ Authoritative: {any}", .{msg.header.flags.authoritative_answer});
    logfn("│ Truncation: {any}", .{msg.header.flags.truncation});
    logfn("│ Recursion desired: {any}", .{msg.header.flags.recursion_desired});
    logfn("│ Recursion available: {any}", .{msg.header.flags.recursion_available});
    logfn("│ Response code: {any}", .{msg.header.flags.response_code});

    logfn("│ Questions: {d}", .{msg.header.number_of_questions});
    logfn("│ Answers: {d}", .{msg.header.number_of_answers});
    logfn("│ Authority records: {d}", .{msg.header.number_of_authority_resource_records});
    logfn("│ Additional records: {d}", .{msg.header.number_of_additional_resource_records});

    for (msg.questions, 0..) |q, i| {
        logfn("│ => Question {d}:", .{i});
        logfn("│ ==> Name: {s}", .{q.name});
        logfn("│ ==> Resource type: {any}", .{q.resource_type});
        logfn("│ ==> Resource class: {any}", .{q.resource_class});
    }

    for (msg.records, 0..) |r, i| {
        logfn("│ => Record {d}:", .{i});
        logRecord(logfn, r);
    }

    for (msg.authority_records, 0..) |r, i| {
        logfn("│ => Authority Record {d}:", .{i});
        logRecord(logfn, r);
    }

    for (msg.additional_records, 0..) |r, i| {
        logfn("│ => Additional Record {d}:", .{i});
        logRecord(logfn, r);
    }

    logfn("└──────", .{});
}

fn logRecord(logfn: anytype, r: data.Record) void {
    logfn("│ ==> Name: {s}", .{r.name});
    logfn("│ ==> Resource type: {any}", .{r.resource_type});
    logfn("│ ==> Resource class: {any}", .{r.resource_class});
    logfn("│ ==> TTL: {d}", .{r.ttl});
    switch (r.resource_type) {
        .A, .AAAA => {
            logfn("│ ==> Data (IP): {any}", .{r.data.ip});
        },
        .PTR => {
            logfn("│ ==> Data (string): {str}", .{r.data.raw});
        },
        .TXT => {
            logfn("│ ==> Data (text): {d}", .{r.data.txt.len});
            for (r.data.txt) |txt| {
                logfn("│ ===> {str}", .{txt});
            }
        },
        .SRV => {
            logfn("│ ==> Data (service): {d} {d} {str}:{d}", .{ r.data.srv.weight, r.data.srv.priority, r.data.srv.target, r.data.srv.port });
        },
        else => {
            logfn("│ ==> Data (bytes): {b}", .{r.data.raw});
        },
    }
}
