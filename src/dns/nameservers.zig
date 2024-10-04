//! Functions to get local DNS nameservers to use for DNS resolution.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Get DNS nameservers.
/// It can return multipe addresses.
/// Memory is owned by the callee.
pub fn getNameservers() ![2]?std.net.Address {
    // Different OSes can have different methods to retrieve default nameserver.
    switch (builtin.os.tag) {
        .windows => {
            return try get_windows_dns_servers();
        },
        else => {
            return try get_resolvconf_dns_servers();
        },
    }
}

test "get nameserver default" {
    const nameservers = try getNameservers();
    try testing.expect(nameservers.len == 2);
}

// Resolv.conf handling

fn get_resolvconf_dns_servers() ![2]?std.net.Address {
    // Look for resolv.conf in default location.
    const resolvconf = try std.fs.openFileAbsolute("/etc/resolv.conf", .{});
    defer resolvconf.close();
    const reader = resolvconf.reader();
    return try parse_resolvconf(reader);
}

fn parse_resolvconf(reader: anytype) ![2]?std.net.Address {
    var i: usize = 0;
    var addresses: [2]?std.net.Address = [2]?std.net.Address{ null, null };

    var buffer: [1024]u8 = undefined;

    // Read resolv.conf line by line.
    while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        // Only interested in lines for "nameserver"
        if (line.len > 10 and std.mem.eql(u8, line[0..10], "nameserver")) {
            // skip whitespace
            var pos: usize = 10;
            while (pos < line.len and std.ascii.isWhitespace(line[pos])) : (pos += 1) {}
            const start: usize = pos;

            // find end of address
            while (pos < line.len and (std.ascii.isHex(line[pos]) or line[pos] == '.' or line[pos] == ':')) : (pos += 1) {}

            // parse address
            const address = std.net.Address.resolveIp(line[start..pos], 53) catch continue;
            addresses[i] = address;
            i += 1;
            if (i == addresses.len) {
                break;
            }
        }
    }

    return addresses;
    // I should have written a parser.
    // Or checked if there is some OS API to retrieve it.
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

    const addresses = try parse_resolvconf(reader);

    const ip4 = try std.net.Address.parseIp4("127.0.0.53", 53);
    const ip6 = try std.net.Address.parseIp6("::ff", 53);

    try testing.expectEqual(2, addresses.len);
    try testing.expect(addresses[0].?.eql(ip4));
    try testing.expect(addresses[1].?.eql(ip6));
}

test "read resolv.conf smaller" {
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
    ;
    var stream = std.io.fixedBufferStream(resolvconf);
    const reader = stream.reader();

    const addresses = try parse_resolvconf(reader);

    const ip4 = try std.net.Address.parseIp4("127.0.0.53", 53);

    try testing.expectEqual(2, addresses.len);
    try testing.expect(addresses[0].?.eql(ip4));
    try testing.expect(addresses[1] == null);
}

// Windows API and Structs for Nameservers

fn get_windows_dns_servers() ![2]?std.net.Address {
    var i: usize = 0;
    var addresses: [2]?std.net.Address = [2]?std.net.Address{ null, null };

    // prepare an empty struct to receive the data
    var info: PFIXED_INFO = std.mem.zeroes(PFIXED_INFO);
    var buf_len: u32 = @sizeOf(PFIXED_INFO);
    // get windows to fill the struct
    const ret = GetNetworkParams(&info, &buf_len);
    if (ret != 0) {
        std.debug.print("GetNetworkParams error {d}\n", .{ret});
        return error.GetNetworkParamsError;
    }

    // first server
    var server = info.DnsServerList;
    while (true) {
        // get size of address
        var len: usize = 0;
        while (server.IpAddress.String[len] != 0) : (len += 1) {}

        // parse address
        const addr = server.IpAddress.String[0..len];
        const address = std.net.Address.parseIp(addr, 53) catch break;
        addresses[i] = address;
        i += 1;
        if (i == addresses.len) {
            break;
        }

        // check if there is more servers
        if (server.Next) |next| {
            server = next.*;
        } else {
            break;
        }
    }

    return addresses;
}

// These is the API and structs used for Windows
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
