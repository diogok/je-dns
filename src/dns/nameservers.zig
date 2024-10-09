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
    src: *IP_ADAPTER_ADDRESSES,
    adapter: *IP_ADAPTER_ADDRESSES,
    dns_server: ?*IP_ADDRESS,

    pub fn init() !@This() {
        // prepare an empty struct to receive the data
        // let windows figure out the size needed
        var buf_len: u32 = 0;
        _ = GetAdaptersAddresses(0, 0, null, null, &buf_len);
        // alloc with windows
        const buffer = HeapAlloc(GetProcessHeap(), 0, buf_len);
        const adapter: *IP_ADAPTER_ADDRESSES = @ptrCast(@alignCast(buffer.?));

        // fill the struct
        const ret = GetAdaptersAddresses(0, 0, null, adapter, &buf_len);

        if (ret != 0) {
            std.debug.print("GetAdaptersAddresses error {d}\n", .{ret});
            return error.GetAdaptersAddressesError;
        }

        return @This(){
            .src = adapter,
            .adapter = adapter,
            .dns_server = adapter.FirstDnsServerAddress,
        };
    }

    pub fn next(self: *@This()) !?std.net.Address {
        if (self.dns_server) |server| {
            if (server.Address.lpSockaddr) |sock_addr| {
                // parse address
                const sockaddr: *align(4) const std.os.windows.ws2_32.sockaddr = @ptrCast(@alignCast(sock_addr));
                var address = std.net.Address.initPosix(sockaddr);
                address.setPort(53);
                // check if there are more servers
                if (server.Next) |next_server| {
                    self.dns_server = next_server;
                } else {
                    self.dns_server = null;
                    // check if there are more adapters
                    if (self.adapter.Next) |next_adapter| {
                        self.adapter = next_adapter;
                        self.dns_server = next_adapter.FirstDnsServerAddress;
                    }
                }
                return address;
            }
        }
        return null;
    }

    pub fn deinit(self: *@This()) void {
        const r = HeapFree(GetProcessHeap(), 0, self.src);
        if (r == 0) {
            std.debug.print("HeapFree failed to free nameservers: {d}\n", .{r});
        }
    }
};

test "Windows DNS Servers" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }
    // Not sure what to test, just making sure it can execute.
    var iter = try WindowsDNSServersIterator.init();
    defer iter.deinit();
    var i: usize = 0;
    while (try iter.next()) |_| {
        i += 1;
    }
    try testing.expect(i >= 1);
}

extern "kernel32" fn GetProcessHeap() callconv(.C) ?*anyopaque;
extern "kernel32" fn HeapAlloc(hHeap: ?*anyopaque, dwFlags: u32, dwBytes: usize) callconv(.C) ?*anyopaque;
extern "kernel32" fn HeapFree(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque) callconv(.C) u32;

extern "iphlpapi" fn GetAdaptersAddresses(
    Family: u32,
    Flags: u32,
    Reserved: ?*anyopaque,
    AdapterAddresses: ?*IP_ADAPTER_ADDRESSES,
    SizePointer: ?*u32,
) callconv(.C) u32;

const IP_ADAPTER_ADDRESSES = extern struct {
    Anonymous1: u64,
    Next: ?*IP_ADAPTER_ADDRESSES,
    AdapterName: ?[*]u8,
    FirstUnicastAddress: ?*extern struct {
        IpAddress: IP_ADDRESS,
        PrefixOrigin: i32,
        SuffixOrigin: i32,
        DadState: i32,
        ValidLifetime: u32,
        PreferredLifetime: u32,
        LeaseLifetime: u32,
        OnLinkPrefixLength: u8,
    },
    FirstAnycastAddress: ?*IP_ADDRESS,
    FirstMulticastAddress: ?*IP_ADDRESS,
    FirstDnsServerAddress: ?*IP_ADDRESS,
    DnsSuffix: ?[*]u16,
    Description: ?[*]u16,
    FriendlyName: ?[*]u16,
    PhysicalAddress: [8]u8,
    PhysicalAddressLength: u32,
    Anonymous2: u32,
    Mtu: u32,
    IfType: u32,
    OperStatus: enum(i32) {
        Up = 1,
        Down = 2,
        Testing = 3,
        Unknown = 4,
        Dormant = 5,
        NotPresent = 6,
        LowerLayerDown = 7,
    },
    Ipv6IfIndex: u32,
    ZoneIndices: [16]u32,
    FirstPrefix: ?*extern struct {
        IpAddress: IP_ADDRESS,
        PrefixLength: u32,
    },
    TransmitLinkSpeed: u64,
    ReceiveLinkSpeed: u64,
    FirstWinsServerAddress: ?*IP_ADDRESS,
    FirstGatewayAddress: ?*IP_ADDRESS,
    Ipv4Metric: u32,
    Ipv6Metric: u32,
    Luid: u64,
    Dhcpv4Server: SOCKET_ADDRESS,
    CompartmentId: u32,
    NetworkGuid: u32,
    ConnectionType: enum(i32) {
        DEDICATED = 1,
        PASSIVE = 2,
        DEMAND = 3,
        MAXIMUM = 4,
    },
    TunnelType: enum(i32) {
        NONE = 0,
        OTHER = 1,
        DIRECT = 2,
        @"6TO4" = 11,
        ISATAP = 13,
        TEREDO = 14,
        IPHTTPS = 15,
    },
    Dhcpv6Server: SOCKET_ADDRESS,
    Dhcpv6ClientDuid: [130]u8,
    Dhcpv6ClientDuidLength: u32,
    Dhcpv6Iaid: u32,
    FirstDnsSuffix: ?*IP_ADAPTER_DNS_SUFFIX,
};

const IP_ADDRESS = extern struct {
    Anonymous: u64,
    Next: ?*IP_ADDRESS,
    Address: SOCKET_ADDRESS,
};

const SOCKET_ADDRESS = extern struct {
    lpSockaddr: ?*SOCKADDR,
    iSockaddrLength: i32,
};

const SOCKADDR = extern struct {
    sa_family: u16,
    sa_data: [14]u8,
};

const IP_ADAPTER_DNS_SUFFIX = extern struct {
    Next: ?*IP_ADAPTER_DNS_SUFFIX,
    String: [256]u16,
};
