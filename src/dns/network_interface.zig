//! Functions to get local DNS nameservers to use for DNS resolution.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const NetworkInterfaceAddress = struct {
    name: []const u8,
    address: std.net.Address,
    up: bool,
};

// posix getifaddrs handling

const sockaddr = std.c.sockaddr;
const IPv4 = std.c.AF.INET;
const IPv6 = std.c.AF.INET6;
const ifaddrs = extern struct {
    next: ?*ifaddrs,
    name: ?[*:0]u8,
    flags: c_uint,
    address: ?*sockaddr,
    netmask: ?*sockaddr,
    specific: extern union {
        broadcast_address: ?*sockaddr,
        point_to_point_address: ?*sockaddr,
    },
    data: ?[*:0]u8,
};
extern "c" fn getifaddrs(ifap: **ifaddrs) callconv(.C) c_int;
extern "c" fn freeifaddrs(ifap: *ifaddrs) callconv(.C) void;

const PosixNetworkInterfaceAddressesIterator = struct {
    ifap: *ifaddrs,
    ifaddrs: ?*ifaddrs,

    pub fn init() !@This() {
        var ifap: ifaddrs = std.mem.zeroes(ifaddrs);
        var self = @This(){
            .ifap = &ifap,
            .ifaddrs = null,
        };
        const r = getifaddrs(&self.ifap);
        if (r != 0) {
            std.debug.print("Error on getifaddrs: {d}\n", .{r});
            return error.getifaddrs;
        }
        self.ifaddrs = self.ifap;
        return self;
    }

    pub fn deinit(self: *@This()) void {
        freeifaddrs(self.ifap);
    }

    pub fn next(self: *@This()) !?NetworkInterfaceAddress {
        while (self.ifaddrs) |ifaddr| {
            if (ifaddr.next) |_| {
                self.ifaddrs = ifaddr.next;
            } else {
                self.ifaddrs = null;
            }
            if (ifaddr.address) |address| {
                if (address.family == IPv4 or address.family == IPv6) {
                    const name: []const u8 = @ptrCast(std.mem.span(ifaddr.name));
                    const sockaddr1: *align(4) const sockaddr = @ptrCast(@alignCast(ifaddr.address));
                    return NetworkInterfaceAddress{
                        .address = std.net.Address.initPosix(sockaddr1),
                        .name = name,
                        .up = ifaddr.flags & 0b1 == 1,
                    };
                }
            }
        }
        return null;
    }
};

test "Poxis NetAddresses" {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    var iter = try PosixNetworkInterfaceAddressesIterator.init();
    defer iter.deinit();

    var i: usize = 0;
    while (try iter.next()) |_| {
        i += 1;
    }
    try testing.expect(i >= 1);
}

// Windows API and Structs for Nameservers

const WindowsNetworkInterfaceAddressesIterator = struct {
    src: *IP_ADAPTER_ADDRESSES,
    curr_adapter: *IP_ADAPTER_ADDRESSES,
    curr_address: ?*IP_ADDRESS,

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

        if (adapter.FirstUnicastAddress) |first_addr| {
            return @This(){
                .src = adapter,
                .curr_adapter = adapter,
                .curr_address = &first_addr.IpAddress,
            };
        } else {
            return error.NoAddress;
        }
    }

    pub fn deinit(self: *@This()) void {
        const r = HeapFree(GetProcessHeap(), 0, self.src);
        if (r == 0) {
            std.debug.print("HeapFree failed to free nameservers: {d}\n", .{r});
        }
    }

    pub fn next(self: *@This()) !?NetworkInterfaceAddress {
        if (self.curr_address) |addr| {
            var address: ?std.net.Address = null;
            if (addr.Address.lpSockaddr) |sock_addr| {
                // parse address
                const sockaddr1: *align(4) const std.os.windows.ws2_32.sockaddr = @ptrCast(@alignCast(sock_addr));
                address = std.net.Address.initPosix(sockaddr1);
            }

            var name: []const u8 = "";
            if (self.curr_adapter.AdapterName) |adapter_name| {
                name = adapter_name[0..10];
            }

            const netinf = NetworkInterfaceAddress{
                .address = address,
                .name = name,
                .up = self.curr_adapter.OperStatus == .Up,
            };

            // check if there are more servers
            if (addr.Next) |next_address| {
                self.curr_address = next_address;
            } else {
                self.curr_address = null;
                // check if there are more adapters
                if (self.curr_adapter.Next) |next_adapter| {
                    if (next_adapter.FirstUnicastAddress) |first_addr| {
                        self.curr_adapter = next_adapter;
                        self.curr_address = &first_addr.IpAddress;
                    }
                }
            }

            return netinf;
        }
        return null;
    }
};

test "Windows NetAddresses" {
    if (builtin.os.tag != .windows) {
        return error.SkipZigTest;
    }
    // Not sure what to test, just making sure it can execute.
    var iter = try WindowsNetworkInterfaceAddressesIterator.init();
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
