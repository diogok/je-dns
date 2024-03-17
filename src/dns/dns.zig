const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const io = @import("io.zig");
const data = @import("data.zig");
const udp = @import("udp.zig");

const log = std.log.scoped(.with_dns);

pub const Options = struct {};

pub fn query(allocator: std.mem.Allocator, question: data.Question, _: Options) !data.Message {
    const servers = try get_dns_servers(allocator);
    defer allocator.free(servers);

    for (servers) |address| {
        log.info("Trying address: {any}", .{address});

        var socket = try udp.Socket.init(allocator, address);
        defer socket.deinit();

        try udp.setTimeout(socket.handle);
        try socket.connect();
        log.info("Connected to {any}", .{address});

        _ = try io.writeQuery(socket.writer(), question);

        try socket.send();
        try socket.receive();

        const reply = try io.readMessage(allocator, socket.reader());
        if (reply.records.len > 0) {
            return reply;
        } else {
            reply.deinit();
        }
    }

    return error.NoAnswer;
}

fn get_dns_servers(allocator: std.mem.Allocator) ![]std.net.Address {
    if (builtin.os.tag == .windows) {
        return try get_windows_dns_servers(allocator);
    } else {
        return try get_resolvconf_dns_servers(allocator);
    }
}

fn get_resolvconf_dns_servers(allocator: std.mem.Allocator) ![]std.net.Address {
    const resolvconf = try std.fs.openFileAbsolute("/etc/resolv.conf", .{});
    defer resolvconf.close();
    const reader = resolvconf.reader();
    return try parse_resolvconf(allocator, reader);
}

fn parse_resolvconf(allocator: std.mem.Allocator, reader: anytype) ![]std.net.Address {
    var addresses = std.ArrayList(std.net.Address).init(allocator);

    var buffer: [1024]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        if (line.len > 10 and std.mem.eql(u8, line[0..10], "nameserver")) {
            var pos: usize = 10;
            while (pos < line.len and std.ascii.isWhitespace(line[pos])) : (pos += 1) {}
            const start: usize = pos;
            while (pos < line.len and (std.ascii.isHex(line[pos]) or line[pos] == '.' or line[pos] == ':')) : (pos += 1) {}
            const address = std.net.Address.resolveIp(line[start..pos], 53) catch continue;
            try addresses.append(address);
        }
    }

    return addresses.toOwnedSlice();
}

test "read resolv.conf" {
    const resolvconf =
        \\;a comment
        \\# another comment
        \\
        \\domain    example.com
        \\
        \\nameserver     127.0.0.53 # comment after
        \\nameserver ::ff
    ;
    var stream = std.io.fixedBufferStream(resolvconf);
    const reader = stream.reader();

    const addresses = try parse_resolvconf(testing.allocator, reader);
    defer testing.allocator.free(addresses);

    const ip4 = try std.net.Address.parseIp4("127.0.0.53", 53);
    const ip6 = try std.net.Address.parseIp6("::ff", 53);

    try testing.expectEqual(2, addresses.len);
    try testing.expect(addresses[0].eql(ip4));
    try testing.expect(addresses[1].eql(ip6));
}

fn get_windows_dns_servers(allocator: std.mem.Allocator) ![]std.net.Address {
    var addresses = std.ArrayList(std.net.Address).init(allocator);

    var info = std.mem.zeroInit(PFIXED_INFO, .{});
    var buf_len: u32 = @intCast(@sizeOf(PFIXED_INFO));
    _ = GetNetworkParams(&info, &buf_len);

    var maybe_server = info.CurrentDnsServer;
    while (maybe_server) |server| {
        var len: usize = 0;
        while (server.IpAddress.String[len] != 0) : (len += 1) {}
        const addr = server.IpAddress.String[0..len];
        const address = std.net.Address.parseIp(addr, 53) catch break;
        try addresses.append(address);
        maybe_server = server.Next;
    }

    return addresses.toOwnedSlice();
}

// Windows API and Struct

extern "iphlpapi" fn GetNetworkParams(pFixedInfo: ?*PFIXED_INFO, pOutBufLen: ?*u32) callconv(.C) u32;

const PFIXED_INFO = extern struct {
    HostName: [132]u8,
    DomainName: [132]u8,
    CurrentDnsServer: ?*IP_ADDR_STRING,
    DnsServerList: IP_ADDR_STRING,
    NodeType: u32,
    ScopeId: [260]u8,
    EnableRouting: u32,
    EnableProxy: u32,
    EnableDns: u32,
};

const IP_ADDR_STRING = extern struct {
    Next: ?*IP_ADDR_STRING,
    IpAddress: IP_ADDRESS_STRING,
    IpMask: IP_ADDRESS_STRING,
    Context: u32,
};

const IP_ADDRESS_STRING = extern struct {
    String: [16]u8,
};
