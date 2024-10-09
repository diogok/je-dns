//! Functions to get local DNS nameservers to use for DNS resolution.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Get DNS nameservers iterator.
/// Callee must deinit the iterator.
pub fn getNameserverIterator() !NSIterator {
    // Different OSes can have different methods to retrieve default nameserver.
    switch (builtin.os.tag) {
        .windows => {
            return try WindowsDNSServersIterator.init();
        },
        else => {
            const resolvconf = try std.fs.openFileAbsolute("/etc/resolv.conf", .{});
            const reader = resolvconf.reader();
            return resolveconfIterator(reader, resolvconf);
        },
    }
}

test "get nameservers" {
    var iter = try getNameserverIterator();
    defer iter.deinit();
    while (try iter.next()) |_| {}
}

pub const NSIterator = if (builtin.os.tag == .windows) WindowsDNSServersIterator else ResolvconfIterator(std.fs.File.Reader, std.fs.File);

// Resolv.conf handling

fn ResolvconfIterator(Reader: type, Closeable: type) type {
    return struct {
        closeable: ?Closeable,
        reader: Reader,
        buffer: [1024]u8 = undefined,

        pub fn init(reader: Reader, closeable: Closeable) @This() {
            return .{ .reader = reader, .closeable = closeable };
        }

        pub fn next(self: *@This()) !?std.net.Address {
            while (try self.reader.readUntilDelimiterOrEof(&self.buffer, '\n')) |line| {
                // Only interested in lines for "nameserver"
                if (line.len > 10 and std.mem.eql(u8, line[0..10], "nameserver")) {
                    // skip whitespace
                    var pos: usize = 10;
                    while (pos < line.len and std.ascii.isWhitespace(line[pos])) : (pos += 1) {}
                    const start: usize = pos;

                    // find end of address
                    while (pos < line.len and (std.ascii.isHex(line[pos]) or line[pos] == '.' or line[pos] == ':')) : (pos += 1) {}

                    // parse address
                    return std.net.Address.resolveIp(line[start..pos], 53) catch continue;
                }
            }
            return null;
        }

        pub fn deinit(self: *@This()) void {
            if (std.meta.hasMethod(Closeable, "close")) {
                if (self.closeable) |closeable| {
                    closeable.close();
                }
            }
        }
    };
}

fn resolveconfIterator(reader: anytype, closeable: anytype) ResolvconfIterator(@TypeOf(reader), @TypeOf(closeable)) {
    return ResolvconfIterator(@TypeOf(reader), @TypeOf(closeable)).init(reader, closeable);
}

test "iter resolv.conf" {
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

    var iter = resolveconfIterator(reader, stream);
    defer iter.deinit();

    const address0 = try iter.next();
    const address1 = try iter.next();
    const address2 = try iter.next();

    const ip4 = try std.net.Address.parseIp4("127.0.0.53", 53);
    const ip6 = try std.net.Address.parseIp6("::ff", 53);

    try testing.expect(address0.?.eql(ip4));
    try testing.expect(address1.?.eql(ip6));
    try testing.expect(address2 == null);
}

// Windows API and Structs for Nameservers

const WindowsDNSServersIterator = struct {
    info: PFIXED_INFO,
    curr: ?IP_ADDR_STRING,

    pub fn init() !@This() {
        // prepare an empty struct to receive the data
        var info: PFIXED_INFO = std.mem.zeroes(PFIXED_INFO);
        var buf_len: u32 = @sizeOf(PFIXED_INFO);
        // get windows to fill the struct
        const ret = GetNetworkParams(&info, &buf_len);
        if (ret != 0) {
            std.debug.print("GetNetworkParams error {d}\n", .{ret});
            return error.GetNetworkParamsError;
        }

        return @This(){
            .info = info,
            .curr = info.DnsServerList,
        };
    }

    pub fn next(self: *@This()) !?std.net.Address {
        if (self.curr) |server| {
            var len: usize = 0;
            while (server.IpAddress.String[len] != 0) : (len += 1) {}

            // parse address
            const addr = server.IpAddress.String[0..len];
            const address = try std.net.Address.parseIp(addr, 53);

            // check if there are more servers
            if (server.Next) |next_server| {
                self.curr = next_server.*;
            } else {
                self.curr = null;
            }

            return address;
        }
        return null;
    }

    pub fn deinit(_: *@This()) void {}
};

test "Windows DNS Servers" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }
    // Not sure what to test, just making sure it can execute.
    var iter = try WindowsDNSServersIterator.init();
    defer iter.deinit();
    while (try iter.next()) |_| {}
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
