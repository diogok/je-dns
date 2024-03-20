const std = @import("std");

pub const Header = packed struct {
    ID: u16 = 0,
    flags: Flags = Flags{},
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
    SOA = 6,
    PTR = 12,
    MX = 15,
    TXT = 16,
    AAAA = 28,
    SRV = 33,

    AFSDB = 18,
    APL = 42,
    CAA = 257,
    CERT = 60,
    CDS = 37,
    CSYNC = 62,
    DHCID = 49,
    DLV = 32769,
    DNAME = 39,
    DNSKEY = 48,
    DS = 43,
    EUI48 = 108,
    EUI64 = 109,
    HINFO = 13,
    HIP = 55,
    HTTPS = 65,
    IPSECKEY = 45,
    KEY = 25,
    KX = 36,
    LOC = 29,
    NAPTR = 35,
    NSEC = 47,
    NSEC3 = 50,
    NSEC3PARAM = 51,
    OPENPGPKEY = 61,
    RP = 17,
    RRSIG = 46,
    SIG = 24,
    SMIMEA = 53,
    SSHFP = 44,
    SVCB = 64,
    TA = 32768,
    TKEY = 249,
    TLSA = 22,
    TSIG = 250,
    URI = 256,
    ZONEMD = 63,
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
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass,
    ttl: u32,
    data: RecordData,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.data.deinit(allocator);
    }
};

pub const RecordData = union(enum) {
    address: std.net.Address,
    bytes: []const u8,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .address => {},
            .bytes => |bytes| {
                allocator.free(bytes);
            },
        }
    }
};

pub const Message = struct {
    header: Header,
    questions: []const Question,
    records: []const Record,
    authority_records: []const Record,
    additional_records: []const Record,

    pub fn initEmpty() @This() {
        return Message{
            .header = Header{},
            .questions = &[_]Question{},
            .records = &[_]Record{},
            .authority_records = &[_]Record{},
            .additional_records = &[_]Record{},
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        for (self.questions) |q| {
            allocator.free(q.name);
        }
        allocator.free(self.questions);

        for (self.records) |r| {
            r.deinit(allocator);
        }
        allocator.free(self.records);

        for (self.authority_records) |r| {
            r.deinit(allocator);
        }
        allocator.free(self.authority_records);

        for (self.additional_records) |r| {
            r.deinit(allocator);
        }
        allocator.free(self.additional_records);
    }
};

pub fn mkid() u16 {
    var rnd = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;
        break :blk seed;
    });
    return rnd.random().int(u16);
}
