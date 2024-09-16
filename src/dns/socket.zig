const std = @import("std");
const builtin = @import("builtin");

pub const Stream = std.io.FixedBufferStream([]u8);

pub const Options = struct {
    socket_type: enum(u32) {
        UDP = std.posix.SOCK.DGRAM,
        //TCP = std.posix.SOCK.STREAM,
    } = .UDP,
    timeout_in_millis: u32 = 100,
    initalize: bool = true,
};

pub const Socket = struct {
    address: std.net.Address,
    handle: std.posix.socket_t,

    recv_buffer: [512]u8 = undefined,
    send_buffer: [512]u8 = undefined,
    send_stream: ?Stream,

    timeout: u32,

    pub fn init(address: std.net.Address, options: Options) !@This() {
        const handle = try std.posix.socket(
            address.any.family,
            @intFromEnum(options.socket_type),
            0,
        );

        var self = @This(){
            .address = address,
            .handle = handle,
            .send_stream = null,
            .timeout = options.timeout_in_millis,
        };

        const send_stream = std.io.fixedBufferStream(&self.send_buffer);
        self.send_stream = send_stream;

        if (options.initalize) {
            try self.setTimeout(options.timeout_in_millis);
            try self.bindOrConnect();
        }

        return self;
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.handle);
    }

    pub fn send(self: *@This()) !void {
        const bytes = self.stream().getWritten();
        if (isMulticast(self.address)) {
            _ = try std.posix.sendto(
                self.handle,
                bytes,
                0,
                &self.address.any,
                self.address.getOsSockLen(),
            );
        } else {
            _ = try std.posix.send(self.handle, bytes, 0);
        }
        self.stream().reset();
    }

    pub fn receive(self: *@This()) !Stream {
        try self.wait();
        const len = try std.posix.recv(self.handle, &self.recv_buffer, 0);
        return std.io.fixedBufferStream(self.recv_buffer[0..len]);
    }

    pub fn wait(self: *@This()) !void {
        if (builtin.os.tag == .windows) {
            var fd_set = std.mem.zeroes(std.os.windows.ws2_32.fd_set);
            fd_set.fd_count = 1;
            fd_set.fd_array[0] = self.handle;
            const pTimeval = makeTimevalue(self.timeout);
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
                .{ .fd = self.handle, .events = 0, .revents = 0 },
            };
            const r = try std.posix.poll(&fds, @as(i32, @intCast(self.timeout)) * 1000);
            if (r == 0) {
                return error.Timeout;
            }
        }
        return;
    }

    pub fn stream(self: *@This()) *Stream {
        return &self.send_stream.?;
    }

    pub fn bindOrConnect(self: *@This()) !void {
        if (isMulticast(self.address)) {
            try self.bind();
        } else {
            try self.connect();
        }
    }

    pub fn bind(self: *@This()) !void {
        try enableReuse(self.handle);
        const bind_addr = try getBindAddress(self.address);
        try std.posix.bind(
            self.handle,
            &bind_addr.any,
            bind_addr.getOsSockLen(),
        );
        if (isMulticast(self.address)) {
            try self.multicast();
        }
    }

    pub fn multicast(self: *@This()) !void {
        try setupMulticast(self.handle, self.address);
        try addMembership(self.handle, self.address);
    }

    pub fn connect(self: *@This()) !void {
        try std.posix.connect(
            self.handle,
            &self.address.any,
            self.address.getOsSockLen(),
        );
    }

    pub fn setTimeout(self: *@This(), millis: u32) !void {
        try setSocketTimeout(self.handle, millis);
    }
};

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

pub fn setSocketTimeout(fd: std.posix.socket_t, millis: u32) !void {
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

pub fn makeTimevalue(millis: u32) std.posix.timeval {
    const micros: i32 = @as(i32, @intCast(millis)) * 1000;

    var timeval: std.posix.timeval = undefined;
    timeval.tv_sec = @as(c_long, @intCast(@divTrunc(micros, 1000000)));
    timeval.tv_usec = @as(c_long, @intCast(@mod(micros, 1000000)));

    return timeval;
}

pub fn enableReuse(sock: std.posix.socket_t) !void {
    if (builtin.os.tag == .linux) {
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
}

pub fn setupMulticast(sock: std.posix.socket_t, address: std.net.Address) !void {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const any = try getAny(address);
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_MULTICAST_IF,
                std.mem.asBytes(&any.in.sa.addr),
            );
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.posix.setsockopt(
                sock,
                IPV4,
                IP_MULTICAST_TTL,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        },
        std.posix.AF.INET6 => {
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_MULTICAST_IF,
                &std.mem.toBytes(@as(c_int, 0)),
            );
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_MULTICAST_HOPS,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.posix.setsockopt(
                sock,
                IPV6,
                IPV6_MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        },
        else => {
            return error.UnkownAddressFamily;
        },
    }
}

pub fn addMembership(sock: std.posix.socket_t, address: std.net.Address) !void {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const any = try getAny(address);
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
        else => {},
    }
}

pub fn getBindAddress(address: std.net.Address) !std.net.Address {
    if (isMulticast(address)) {
        return try getAny(address);
    } else {
        return address;
    }
}

pub fn getAny(address: std.net.Address) !std.net.Address {
    switch (address.any.family) {
        std.posix.AF.INET => {
            return try std.net.Address.parseIp4("0.0.0.0", 5353);
        },
        std.posix.AF.INET6 => {
            return try std.net.Address.parseIp6("::", 5353);
        },
        else => {
            return error.UnkownAddressFamily;
        },
    }
}

const testing = std.testing;

test "Socket connect ip4 localhost" {
    const server = try std.net.Address.parseIp("127.0.0.1", 53);
    var sock = try Socket.init(server, .{});
    sock.deinit();
}

test "Socket connect ip4 multicast" {
    const server = try std.net.Address.parseIp("224.0.0.251", 5353);
    var sock = try Socket.init(server, .{});
    sock.deinit();
}

test "Socket connect ip6 localhost" {
    const server = try std.net.Address.parseIp("::1", 53);
    var sock = try Socket.init(server, .{});
    sock.deinit();
}

test "Socket connect ip6 multicast" {
    const server = try std.net.Address.parseIp("ff02::fb", 5353);
    var sock = try Socket.init(server, .{});
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
