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
