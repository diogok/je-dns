const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// Nameserver logic

pub fn getNameservers(allocator: std.mem.Allocator, local: bool) ![]std.net.Address {
    if (local) {
        return try getMulticast(allocator);
    } else {
        return try getDefaultNameservers(allocator);
    }
}

test "get nameserver default" {
    const nameservers = try getNameservers(testing.allocator, false);
    defer testing.allocator.free(nameservers);
    try testing.expect(nameservers.len >= 1);
}

test "get nameserver local domain" {
    const nameservers = try getNameservers(testing.allocator, true);
    defer testing.allocator.free(nameservers);
    try testing.expect(nameservers.len >= 1);
}

fn getDefaultNameservers(allocator: std.mem.Allocator) ![]std.net.Address {
    if (builtin.os.tag == .windows) {
        return try get_windows_dns_servers(allocator);
    } else {
        return try get_resolvconf_dns_servers(allocator);
    }
}

fn getMulticast(allocator: std.mem.Allocator) ![]std.net.Address {
    const addresses = try allocator.alloc(std.net.Address, 2);
    addresses[0] = try std.net.Address.parseIp("ff02::fb", 5353);
    addresses[1] = try std.net.Address.parseIp("224.0.0.251", 5353);
    return addresses;
}

// Resolv.conf

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
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
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

// Windows API and Structs for Nameservers

fn get_windows_dns_servers(allocator: std.mem.Allocator) ![]std.net.Address {
    var addresses = std.ArrayList(std.net.Address).init(allocator);

    var info: PFIXED_INFO = std.mem.zeroes(PFIXED_INFO);
    var buf_len: u32 = @sizeOf(PFIXED_INFO);
    const ret = GetNetworkParams(&info, &buf_len);
    if (ret != 0) {
        return error.WindowsError;
    }

    var server = info.DnsServerList;
    while (true) {
        var len: usize = 0;
        while (server.IpAddress.String[len] != 0) : (len += 1) {}
        const addr = server.IpAddress.String[0..len];
        const address = std.net.Address.parseIp(addr, 53) catch break;
        try addresses.append(address);
        if (server.Next) |next| {
            server = next.*;
        } else {
            break;
        }
    }

    return addresses.toOwnedSlice();
}

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
