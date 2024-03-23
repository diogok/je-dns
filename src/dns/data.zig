const std = @import("std");
const builtin = @import("builtin");

pub const Message = struct {
    header: Header = Header{},
    questions: []const Question = &[_]Question{},
    records: []const Record = &[_]Record{},
    authority_records: []const Record = &[_]Record{},
    additional_records: []const Record = &[_]Record{},

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

pub const Header = packed struct {
    ID: u16 = 0,
    flags: Flags = Flags{},
    number_of_questions: u16 = 0,
    number_of_answers: u16 = 0,
    number_of_authority_resource_records: u16 = 0,
    number_of_additional_resource_records: u16 = 0,

    pub fn read(stream: anytype) !Header {
        var reader = stream.reader();
        return Header{
            .ID = try reader.readInt(u16, .big),
            .flags = try Flags.read(reader),
            .number_of_questions = try reader.readInt(u16, .big),
            .number_of_answers = try reader.readInt(u16, .big),
            .number_of_authority_resource_records = try reader.readInt(u16, .big),
            .number_of_additional_resource_records = try reader.readInt(u16, .big),
        };
    }
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

    pub fn read(reader: anytype) !@This() {
        var flag_bits = try reader.readInt(u16, .big);
        if (builtin.cpu.arch.endian() == .little) {
            flag_bits = @bitReverse(flag_bits);
        }
        return @bitCast(flag_bits);
    }
};

pub const Question = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass = .IN,

    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
        const name = try readName(allocator, stream);
        errdefer allocator.free(name);

        var reader = stream.reader();
        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);

        return @This(){
            .name = name,
            .resource_type = @enumFromInt(r_type),
            .resource_class = @enumFromInt(r_class & 0b1),
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const Record = struct {
    name: []const u8,
    resource_type: ResourceType,
    resource_class: ResourceClass,
    ttl: u32,
    data: RecordData,

    pub fn read(allocator: std.mem.Allocator, stream: anytype) !@This() {
        const name = try readName(allocator, stream);
        errdefer allocator.free(name);

        var reader = stream.reader();
        const r_type = try reader.readInt(u16, .big);
        const r_class = try reader.readInt(u16, .big);
        const ttl = try reader.readInt(u32, .big);

        const resource_type: ResourceType = @enumFromInt(r_type);
        const resource_class: ResourceClass = @enumFromInt(r_class & 0b1);

        const extra = try RecordData.read(allocator, resource_type, stream);

        return @This(){
            .resource_type = resource_type,
            .resource_class = resource_class,
            .ttl = ttl,
            .name = name,
            .data = extra,
        };
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.data.deinit(allocator);
    }
};

pub const RecordData = union(enum) {
    ip: std.net.Address,
    srv: struct {
        priority: u16,
        weight: u16,
        port: u16,
        target: []const u8,
    },
    txt: []const []const u8,
    ptr: []const u8,
    raw: []const u8,

    pub fn read(allocator: std.mem.Allocator, resource_type: ResourceType, stream: anytype) !@This() {
        var reader = stream.reader();

        const len = try reader.readInt(u16, .big);
        const pos = try stream.getPos();
        defer stream.seekTo(len + pos) catch unreachable;

        switch (resource_type) {
            .A => {
                var bytes: [4]u8 = undefined;
                _ = try reader.read(&bytes);
                return .{ .ip = std.net.Address.initIp4(bytes, 0) };
            },
            .AAAA => {
                var bytes: [16]u8 = undefined;
                _ = try reader.read(&bytes);
                return .{ .ip = std.net.Address.initIp6(bytes, 0, 0, 0) };
            },
            .PTR => {
                return .{ .ptr = try readName(allocator, stream) };
            },
            .SRV => {
                return .{
                    .srv = .{
                        .weight = try reader.readInt(u16, .big),
                        .priority = try reader.readInt(u16, .big),
                        .port = try reader.readInt(u16, .big),
                        .target = try readName(allocator, stream),
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
                while (total < len) {
                    const txt_len = try reader.readByte();
                    const txt = try allocator.alloc(u8, txt_len);
                    errdefer allocator.free(txt);

                    _ = try reader.read(txt);
                    total += len + 1;

                    try txts.append(txt);
                }

                return .{ .txt = try txts.toOwnedSlice() };
            },
            else => {
                const bytes = try allocator.alloc(u8, len);
                _ = try reader.read(bytes);
                return .{ .raw = bytes };
            },
        }
    }

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        switch (self) {
            .ip => {},
            .srv => |srv| {
                allocator.free(srv.target);
            },
            .txt => |text| {
                for (text) |txt| {
                    allocator.free(txt);
                }
                allocator.free(text);
            },
            .ptr => |ptr| {
                allocator.free(ptr);
            },
            .raw => |bytes| {
                allocator.free(bytes);
            },
        }
    }
};

fn readName(allocator: std.mem.Allocator, stream: anytype) ![]const u8 {
    var name_buffer = std.ArrayList(u8).init(allocator);
    defer name_buffer.deinit();

    var seekBackTo: u64 = 0;

    var reader = stream.reader();
    while (true) {
        const len = try reader.readByte();
        if (len == 0) {
            break;
        } else if (len >= 192) {
            const ptr0: u8 = len & 0b00111111;
            const ptr1: u8 = try reader.readByte();
            const ptr = (@as(u16, ptr0) << 8) + @as(u16, ptr1);
            if (seekBackTo == 0) {
                seekBackTo = try stream.getPos();
            }
            try stream.seekTo(ptr);
        } else {
            if (name_buffer.items.len > 0) try name_buffer.append('.');
            const label = try name_buffer.addManyAsSlice(len);
            _ = try reader.read(label);
        }
    }

    if (seekBackTo > 0) {
        try stream.seekTo(seekBackTo);
    }

    return try name_buffer.toOwnedSlice();
}

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

pub fn mkid() u16 {
    return @truncate(@as(u64, @bitCast(std.time.timestamp())));
}

pub fn readAll(allocator: std.mem.Allocator, stream: anytype, Type: type, n: usize) ![]const Type {
    var i: usize = 0;
    const data = try allocator.alloc(Type, n);
    errdefer {
        for (data[0..i]) |d| {
            d.deinit(allocator);
        }
        allocator.free(data);
    }
    while (i < n) : (i += 1) {
        data[i] = try Type.read(allocator, stream);
    }
    return data;
}

pub fn deinitAll(allocator: std.mem.Allocator, data: anytype) void {
    for (data) |d| {
        d.deinit(allocator);
    }
    allocator.free(data);
}
