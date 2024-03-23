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

pub fn readMessage(allocator: std.mem.Allocator, bytes: []const u8) !data.Message {
    var stream = std.io.fixedBufferStream(bytes);

    const header = try data.Header.read(&stream);

    const questions = try data.readAll(allocator, &stream, data.Question, header.number_of_questions);
    errdefer data.deinitAll(allocator, questions);

    const records = try data.readAll(allocator, &stream, data.Record, header.number_of_answers);
    errdefer data.deinitAll(allocator, records);

    const authority_records = try data.readAll(allocator, &stream, data.Record, header.number_of_authority_resource_records);
    errdefer data.deinitAll(allocator, authority_records);

    const additional_records = try data.readAll(allocator, &stream, data.Record, header.number_of_additional_resource_records);
    errdefer data.deinitAll(allocator, additional_records);

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

    const reply = try readMessage(testing.allocator, buffer[0..]);
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
