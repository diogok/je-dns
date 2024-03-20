const std = @import("std");

pub const Header = packed struct {
    ID: u16,
    flags: Flags,
    number_of_questions: u16 = 0,
    number_of_answers: u16 = 0,
    number_of_authority_resource_records: u16 = 0,
    number_of_additional_resource_records: u16 = 0,
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
};

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
    PTR = 12,
    TXT = 16,
    AAAA = 28,
    SRV = 33,
    _,
};

pub const ResourceClass = enum(u16) {
    IN = 1,
    _,
};

pub const Question = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass = .IN,
};

pub const Record = struct {
    resource_type: ResourceType,
    resource_class: ResourceClass,
    ttl: u32,
    data: []const u8,
    name: []const u8,
};

pub const Message = struct {
    allocator: ?std.mem.Allocator = null,

    header: Header,
    questions: []const Question,
    records: []const Record,

    pub fn deinit(self: @This()) void {
        if (self.allocator) |allocator| {
            for (self.questions) |q| {
                allocator.free(q.name);
            }
            allocator.free(self.questions);
            for (self.records) |r| {
                allocator.free(r.name);
                allocator.free(r.data);
            }
            allocator.free(self.records);
        }
    }
};
