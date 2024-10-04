//! UDP socket functions for IPv4 and IPv6.

const std = @import("std");
const builtin = @import("builtin");

/// A byte stream.
pub const Stream = std.io.FixedBufferStream([]u8);

/// Options for creating an UDP Socket.
pub const Options = struct {
    /// Timeout in milliseconds.
    /// 1000 milliseconds is 1 second.
    /// Default to 100ms (0.1s).
    timeout_in_millis: u32 = 100,
};

/// This is a utility to connect, send and receive data from a UDP socket.
/// Works for IPv4 and IPv6.
pub const Socket = struct {
    address: std.net.Address,
    handle: std.posix.socket_t,

    /// Timeout in milliseconds.
    timeout_in_millis: u32,

    /// Creates a new socket object.
    /// Should call deinit after usage.
    pub fn init(address: std.net.Address, options: Options) !@This() {
        const handle = try std.posix.socket(
            address.any.family,
            std.posix.SOCK.DGRAM,
            0,
        );

        try setTimeout(handle, options.timeout_in_millis);

        return @This(){
            .address = address,
            .handle = handle,
            .timeout_in_millis = options.timeout_in_millis,
        };
    }

    /// Closes the socket.
    pub fn deinit(self: @This()) void {
        std.posix.close(self.handle);
    }

    /// Send the data (up to 512 bytes) in single packet.
    /// Timeout applies.
    pub fn sendBytes(self: @This(), bytes: []const u8) !void {
        std.debug.assert(bytes.len <= 512);
        _ = try std.posix.sendto(
            self.handle,
            bytes,
            0,
            &self.address.any,
            self.address.getOsSockLen(),
        );
    }

    /// Receives the next message on the socket.
    /// On timeout, returns an error.
    /// Will call Select or Poll to wait for messages.
    pub fn receive(self: @This(), buffer: []u8) !usize {
        // First wait for messages to be available.
        try self.wait();
        // Read the message into the buffer.
        const len = try std.posix.recv(self.handle, buffer, 0);
        // Return the length of received data.
        return len;
    }

    /// Wait for a message to be available.
    /// Uses select on windows and poll on other OSes.
    fn wait(self: @This()) !void {
        if (builtin.os.tag == .windows) {
            var fd_set = std.mem.zeroes(std.os.windows.ws2_32.fd_set);
            fd_set.fd_count = 1;
            fd_set.fd_array[0] = self.handle;
            const pTimeval = makeTimevalue(self.timeout_in_millis);
            const timeval = std.os.windows.ws2_32.timeval{
                .tv_sec = pTimeval.tv_sec,
                .tv_usec = pTimeval.tv_usec,
            };
            const timeout: ?*const @TypeOf(timeval) = &timeval;
            const r = std.os.windows.ws2_32.select(1, &fd_set, null, null, timeout);
            if (r == 0) {
                return error.Timeout;
            }
        } else {
            var fds = [_]std.posix.pollfd{
                .{ .fd = self.handle, .events = 1, .revents = 0 },
            };
            const r = try std.posix.poll(&fds, @as(i32, @intCast(self.timeout_in_millis)));
            if (r == 0) {
                return error.Timeout;
            }
        }
        return;
    }

    /// Bind to specific address. Can be the same of self.address.
    pub fn bind(self: @This()) !void {
        try enableReuse(self.handle);
        const bind_address = try getBindAddress(self.address);
        try std.posix.bind(
            self.handle,
            &bind_address.any,
            bind_address.getOsSockLen(),
        );
    }

    /// Setup multicast for this socket.
    pub fn multicast(self: @This()) !void {
        try setupMulticast(self.handle, self.address, .{});
    }
};

/// Detects if this is a multicast address.
pub fn isMulticast(address: std.net.Address) bool {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const addr = address.in.sa.addr;
            const bytes = std.mem.toBytes(addr);
            return bytes[0] & 0xF0 == 0xE0;
        },
        std.posix.AF.INET6 => {
            return address.in6.sa.addr[0] >= 0xFF;
        },
        else => {
            return false;
        },
    }
}

/// Set send and receive timeout on the socket.
pub fn setTimeout(fd: std.posix.socket_t, millis: u32) !void {
    const timeout = makeTimevalue(millis);
    const value: []const u8 = std.mem.toBytes(timeout)[0..];
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        value,
    );
    try std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        value,
    );
}

/// Make a timevalue, to be used on timeout functions.
pub fn makeTimevalue(millis: u32) std.posix.timeval {
    const micros: i32 = @as(i32, @intCast(millis)) * 1000;

    var timeval: std.posix.timeval = undefined;
    timeval.tv_sec = @as(c_long, @intCast(@divTrunc(micros, 1000000)));
    timeval.tv_usec = @as(c_long, @intCast(@mod(micros, 1000000)));

    return timeval;
}

/// Enable reuse of a socket, so multiple process can bind to it.
/// Required for multicast, recommended for the rest.
pub fn enableReuse(sock: std.posix.socket_t) !void {
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
}

/// Common options for Multicast setupts.
pub const MulticastOptions = struct {
    /// How many network hops can the message go.
    /// 0 is only the original machine.
    /// 1 is original machine + 1, which usually means your direct network (eth, wi-fi, vpn).
    hops: u8 = 1,
    /// Loop means the sender will receive it's own messages.
    /// Useful to debug.
    loop: bool = true,
};

/// Setup multicast options, specially for using mDNS.
/// Works for IPv4 and IPv6.
/// Will setup: Multicast interface (IF), Loop, Hops and Membership.
pub fn setupMulticast(
    sock: std.posix.socket_t,
    address: std.net.Address,
    options: MulticastOptions,
) !void {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const any = try getAny(address);
            // Setup for multicast.
            // For IPv4, you set the multicast interface to the 'any' address.
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_MULTICAST_IF,
                std.mem.asBytes(&any.in.sa.addr),
            );
            // Should receive it's own messages
            var loop: u1 = 0;
            if (options.loop) {
                loop = 1;
            }
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, loop)),
            );
            // How many 'hops' (ie.: network machines) it will cross.
            // Set to 1 to use only on immediate network (own machine + 1).
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_MULTICAST_TTL,
                &std.mem.toBytes(@as(c_int, options.hops)),
            );

            // This will add our address to receive messages on the multicast "any" address.
            const membership = extern struct {
                addr: u32,
                any: u32,
            }{
                .addr = address.in.sa.addr,
                .any = any.in.sa.addr,
            };
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_ADD_MEMBERSHIP,
                std.mem.asBytes(&membership),
            );
        },
        std.posix.AF.INET6 => {
            // Setup for multicast.
            // For IPv6 you choose a network interface.
            // 0 means default
            // Should we loop and do all interfaces?
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_MULTICAST_IF,
                &std.mem.toBytes(@as(c_int, 0)),
            );
            // How many 'hops' (ie.: network machines) it will cross.
            // Set to 1 to use only on immediate network (own machine + 1).
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_MULTICAST_HOPS,
                &std.mem.toBytes(@as(c_int, options.hops)),
            );
            // Should receive it's own messages
            var loop: u1 = 0;
            if (options.loop) {
                loop = 1;
            }
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, loop)),
            );

            // Ipv6 Add membership to the default interface (0)
            const membership = extern struct {
                addr: [16]u8,
                index: c_uint,
            }{
                .addr = address.in6.sa.addr,
                .index = 0,
            };
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_ADD_MEMBERSHIP,
                std.mem.asBytes(&membership),
            );
        },
        else => {
            return error.UnkownAddressFamily;
        },
    }
}

/// The the bind address.
/// For multicast, you should bind to "any" address.
/// For others, to the address itself.
pub fn getBindAddress(address: std.net.Address) !std.net.Address {
    if (isMulticast(address)) {
        return try getAny(address);
    } else {
        return address;
    }
}

/// Get the "any" address of any address.
/// Example: "0.0.0.0" or "::"
pub fn getAny(address: std.net.Address) !std.net.Address {
    switch (address.any.family) {
        std.posix.AF.INET => {
            return std.net.Address.initIp4([4]u8{ 0, 0, 0, 0 }, address.getPort());
        },
        std.posix.AF.INET6 => {
            return std.net.Address.initIp6(std.mem.zeroes([16]u8), address.getPort(), 0, 0);
        },
        else => {
            return error.UnkownAddressFamily;
        },
    }
}

const testing = std.testing;

test "Socket connect ip4 localhost" {
    const server = try std.net.Address.parseIp("127.0.0.1", 1234);
    var sock = try Socket.init(server, .{});
    try sock.bind();
    sock.deinit();
}

test "Socket connect ip4 multicast" {
    const server = try std.net.Address.parseIp("224.0.0.251", 5353);
    var sock = try Socket.init(server, .{});
    try sock.bind();
    try sock.multicast();
    sock.deinit();
}

test "Socket connect ip6 localhost" {
    const server = try std.net.Address.parseIp("::1", 1234);
    var sock = try Socket.init(server, .{});
    try sock.bind();
    sock.deinit();
}

test "Socket connect ip6 multicast" {
    const server = try std.net.Address.parseIp("ff02::fb", 5353);
    var sock = try Socket.init(server, .{});
    try sock.bind();
    try sock.multicast();
    sock.deinit();
}

const IPV4 = switch (builtin.os.tag) {
    .windows => 0,
    .linux => 0,
    else => @compileError("UNSUPPORTED OS"),
};

const IPV6 = switch (builtin.os.tag) {
    .windows => 41,
    .linux => 41,
    else => @compileError("UNSUPPORTED OS"),
};

const IP_MULTICAST_IF = switch (builtin.os.tag) {
    .windows => 9,
    .linux => 32,
    else => @compileError("UNSUPPORTED OS"),
};

const IP_MULTICAST_TTL = switch (builtin.os.tag) {
    .windows => 3,
    .linux => 33,
    else => @compileError("UNSUPPORTED OS"),
};

const IP_MULTICAST_LOOP = switch (builtin.os.tag) {
    .windows => 11,
    .linux => 34,
    else => @compileError("UNSUPPORTED OS"),
};

const IP_ADD_MEMBERSHIP = switch (builtin.os.tag) {
    .windows => 12,
    .linux => 35,
    else => @compileError("UNSUPPORTED OS"),
};

const IPV6_MULTICAST_IF = switch (builtin.os.tag) {
    .windows => 9,
    .linux => 17,
    else => @compileError("UNSUPPORTED OS"),
};

const IPV6_MULTICAST_HOPS = switch (builtin.os.tag) {
    .windows => 10,
    .linux => 18,
    else => @compileError("UNSUPPORTED OS"),
};

const IPV6_MULTICAST_LOOP = switch (builtin.os.tag) {
    .windows => 11,
    .linux => 19,
    else => @compileError("UNSUPPORTED OS"),
};

const IPV6_ADD_MEMBERSHIP = switch (builtin.os.tag) {
    .windows => 12,
    .linux => 20,
    else => @compileError("UNSUPPORTED OS"),
};
