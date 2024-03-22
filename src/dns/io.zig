const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const data = @import("data.zig");

const log = std.log.scoped(.with_dns);

pub fn writeMessage(writer: anytype, message: data.Message) !void {
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

pub fn readMessage(allocator: std.mem.Allocator, reader0: anytype) !data.Message {
    // read all of the request, because we might need the all bytes for pointer/compressed labels
    const all_bytes = try reader0.readAllAlloc(allocator, 4096);
    defer allocator.free(all_bytes);

    var stream = std.io.fixedBufferStream(all_bytes);
    const reader = stream.reader();

    const header = try readHeader(reader);
    const questions = try readQuestions(allocator, header.number_of_questions, reader, all_bytes);
    errdefer {
        for (questions) |q| {
            allocator.free(q.name);
        }
        allocator.free(questions);
    }

    const records = try readRecords(allocator, header.number_of_answers, reader, all_bytes);
    errdefer {
        for (records) |r| {
            r.deinit(allocator);
        }
        allocator.free(records);
    }

    const authority_records = try readRecords(allocator, header.number_of_authority_resource_records, reader, all_bytes);
    errdefer {
        for (authority_records) |r| {
            r.deinit(allocator);
        }
        allocator.free(authority_records);
    }

    const additional_records = try readRecords(allocator, header.number_of_additional_resource_records, reader, all_bytes);
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

fn readHeader(reader: anytype) !data.Header {
    const id = try reader.readInt(u16, .big);
    var flag_bits = try reader.readInt(u16, .big);
    if (builtin.cpu.arch.endian() == .little) {
        flag_bits = @bitReverse(flag_bits);
    }
    return data.Header{
        .ID = id,
        .flags = @bitCast(flag_bits),
        .number_of_questions = try reader.readInt(u16, .big),
        .number_of_answers = try reader.readInt(u16, .big),
        .number_of_authority_resource_records = try reader.readInt(u16, .big),
        .number_of_additional_resource_records = try reader.readInt(u16, .big),
    };
}
fn readQuestions(allocator: std.mem.Allocator, n: usize, reader: anytype, all_bytes: []const u8) ![]data.Question {
    var i: usize = 0;

    var questions = try allocator.alloc(data.Question, n);
    errdefer {
        for (questions[0..i]) |q| {
            allocator.free(q.name);
        }
        allocator.free(questions);
    }

    while (i < n) : (i += 1) {
        const name = try readName(allocator, reader, all_bytes);
        errdefer allocator.free(name);

        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);
        const question = data.Question{
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class & 0b1),
        };

        questions[i] = question;
    }
    return questions;
}

fn readRecords(allocator: std.mem.Allocator, n: usize, reader: anytype, all_bytes: []const u8) ![]data.Record {
    var i: usize = 0;

    var records = try allocator.alloc(data.Record, n);
    errdefer {
        for (records[0..i]) |r| {
            r.deinit(allocator);
        }
        allocator.free(records);
    }

    while (i < n) : (i += 1) {
        const name = try readName(allocator, reader, all_bytes);
        errdefer allocator.free(name);

        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);
        const ttl = try reader.readInt(u32, .big);
        const data_len = try reader.readInt(u16, .big);

        const resource_type: data.ResourceType = @enumFromInt(r_type);
        const resource_class: data.ResourceClass = @enumFromInt(r_class & 0b1);

        const extra_bytes = try allocator.alloc(u8, data_len);
        defer allocator.free(extra_bytes);
        _ = try reader.read(extra_bytes);

        const extra = try readRecordData(allocator, resource_type, extra_bytes, all_bytes);

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

fn readRecordData(
    allocator: std.mem.Allocator,
    resource_type: data.ResourceType,
    data_bytes: anytype,
    all_bytes: []const u8,
) !data.RecordData {
    var stream = std.io.fixedBufferStream(data_bytes);
    var reader = stream.reader();
    switch (resource_type) {
        .A => {
            return .{ .ip = std.net.Address.initIp4(data_bytes[0..4].*, 0) };
        },
        .AAAA => {
            return .{ .ip = std.net.Address.initIp6(data_bytes[0..16].*, 0, 0, 0) };
        },
        .PTR => {
            return .{ .ptr = try readName(allocator, reader, all_bytes) };
        },
        .SRV => {
            const weight = try reader.readInt(u16, .big);
            const priority = try reader.readInt(u16, .big);
            const port = try reader.readInt(u16, .big);
            const target = try readName(allocator, reader, all_bytes);
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
            var txts = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (txts.items) |text| {
                    allocator.free(text);
                }
                txts.deinit();
            }

            var total: usize = 0;
            while (total < data_bytes.len) {
                const len = try reader.readByte();
                total += 1;

                const txt = try allocator.alloc(u8, len);
                errdefer allocator.free(txt);

                _ = try reader.read(txt);
                total += len;

                try txts.append(txt);
            }
            return .{ .txt = try txts.toOwnedSlice() };
        },
        else => {
            return .{ .raw = try reader.readAllAlloc(allocator, data_bytes.len) };
        },
    }
}

fn readName(allocator: std.mem.Allocator, reader: anytype, all_bytes: []const u8) ![]const u8 {
    var name_buffer = std.ArrayList(u8).init(allocator);
    defer name_buffer.deinit();

    var len = try reader.readByte();
    while (len > 0) {
        if (len >= 192) {
            const ptr0: u8 = len & 0b00111111;
            const ptr1: u8 = try reader.readByte();
            const ptr: u16 = (@as(u16, ptr0) << 8) + @as(u16, ptr1);

            var stream = std.io.fixedBufferStream(all_bytes[ptr..]);
            const re_reader = stream.reader();

            const label = try readName(allocator, re_reader, all_bytes);
            defer allocator.free(label);
            try name_buffer.appendSlice(label);

            break;
        } else {
            const label = try allocator.alloc(u8, len);
            defer allocator.free(label);
            _ = try reader.read(label);
            try name_buffer.appendSlice(label);

            len = try reader.readByte();
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
            logfn("│ ==> Data (string): {str}", .{r.data.ptr});
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
