const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

pub const Stream = std.io.FixedBufferStream([]u8);

pub const SocketOptions = struct {
    socket_type: enum(u32) {
        UDP = std.os.SOCK.DGRAM,
        TCP = std.os.SOCK.STREAM,
    } = .UDP,
    timeout_in_millis: i32 = 1000,
    buffer_size: usize = 0, // 0 means auto
};

pub const Socket = struct {
    allocator: std.mem.Allocator,

    address: std.net.Address,
    handle: std.os.socket_t,

    recv_buffer: []u8,
    send_buffer: []u8,
    stream: Stream,

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address, options: SocketOptions) !@This() {
        const handle = try std.os.socket(
            address.any.family,
            @intFromEnum(options.socket_type),
            0,
        );

        try setTimeout(handle, options.timeout_in_millis);

        // TODO: check system packet size
        const recv_buffer = try allocator.alloc(u8, 512);
        const send_buffer = try allocator.alloc(u8, 512);
        const stream = std.io.fixedBufferStream(send_buffer);

        return @This(){
            .allocator = allocator,
            .address = address,
            .handle = handle,
            .recv_buffer = recv_buffer,
            .send_buffer = send_buffer,
            .stream = stream,
        };
    }

    pub fn deinit(self: *@This()) void {
        std.os.close(self.handle);
        self.allocator.free(self.recv_buffer);
        self.allocator.free(self.send_buffer);
    }

    pub fn connect(self: *@This()) !void {
        try std.os.connect(self.handle, &self.address.any, self.address.getOsSockLen());
    }

    pub fn bind(self: *@This()) !void {
        try enableReuse(self.handle);
        try std.os.bind(self.handle, &self.address.any, self.address.getOsSockLen());
    }

    pub fn multicast(self: *@This(), mc_address: std.net.Address) !void {
        try setupMulticast(self.handle, mc_address);
        try addMembership(self.handle, mc_address);
    }

    pub fn send(self: *@This()) !void {
        const bytes = self.stream.getWritten();
        _ = try std.os.send(self.handle, bytes, 0);
        self.stream.reset();
    }

    pub fn sendTo(self: *@This(), address: std.net.Address) !void {
        const bytes = self.stream.getWritten();
        _ = try std.os.sendto(self.handle, bytes, 0, &address.any, address.getOsSockLen());
        self.stream.reset();
    }

    pub fn receive(self: *@This()) !Stream {
        const len = try std.os.recv(self.handle, self.recv_buffer, 0);
        return std.io.fixedBufferStream(self.recv_buffer[0..len]);
    }
};

pub fn setTimeout(fd: std.os.socket_t, millis: i32) !void {
    const micros: i32 = millis * 1000;
    if (micros > 0) {
        var timeout: std.os.timeval = undefined;
        timeout.tv_sec = @as(c_long, @intCast(@divTrunc(micros, 1000000)));
        timeout.tv_usec = @as(c_long, @intCast(@mod(micros, 1000000)));
        try std.os.setsockopt(
            fd,
            std.os.SOL.SOCKET,
            std.os.SO.RCVTIMEO,
            std.mem.toBytes(timeout)[0..],
        );
        try std.os.setsockopt(
            fd,
            std.os.SOL.SOCKET,
            std.os.SO.SNDTIMEO,
            std.mem.toBytes(timeout)[0..],
        );
    }
}

pub fn enableReuse(sock: std.os.socket_t) !void {
    if (builtin.os.tag != .windows) {
        try std.os.setsockopt(
            sock,
            std.os.SOL.SOCKET,
            std.os.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }
    try std.os.setsockopt(
        sock,
        std.os.SOL.SOCKET,
        std.os.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
}

pub fn setupMulticast(sock: std.os.socket_t, address: std.net.Address) !void {
    switch (address.any.family) {
        std.os.AF.INET => {
            const any = try getAny(address);
            try std.os.setsockopt(
                sock,
                std.os.SOL.IP,
                std.os.system.IP.MULTICAST_IF,
                std.mem.asBytes(&any.in.sa.addr),
            );
            try std.os.setsockopt(
                sock,
                std.os.SOL.IP,
                std.os.system.IP.MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.os.setsockopt(
                sock,
                std.os.SOL.IP,
                std.os.system.IP.MULTICAST_TTL,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        },
        std.os.AF.INET6 => {
            try std.os.setsockopt(
                sock,
                std.os.SOL.IPV6,
                std.os.system.IPV6.MULTICAST_IF,
                &std.mem.toBytes(@as(c_int, 0)),
            );
            try std.os.setsockopt(
                sock,
                std.os.SOL.IPV6,
                std.os.system.IPV6.MULTICAST_HOPS,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.os.setsockopt(
                sock,
                std.os.SOL.IPV6,
                std.os.system.IPV6.MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        },
        else => {},
    }
}

pub fn addMembership(sock: std.os.socket_t, address: std.net.Address) !void {
    switch (address.any.family) {
        std.os.AF.INET => {
            const any = try getAny(address);
            const membership = extern struct {
                addr: u32,
                any: u32,
            }{
                .addr = address.in.sa.addr,
                .any = any.in.sa.addr,
            };
            try std.os.setsockopt(
                sock,
                std.os.SOL.IP,
                std.os.linux.IP.ADD_MEMBERSHIP,
                std.mem.asBytes(&membership),
            );
        },
        std.os.AF.INET6 => {
            const membership = extern struct {
                addr: [16]u8,
                index: c_uint,
            }{
                .addr = address.in6.sa.addr,
                .index = 0,
            };
            try std.os.setsockopt(
                sock,
                std.os.SOL.IPV6,
                std.os.system.IPV6.ADD_MEMBERSHIP,
                std.mem.asBytes(&membership),
            );
        },
        else => {},
    }
}

pub fn getAny(address: std.net.Address) !std.net.Address {
    switch (address.any.family) {
        std.os.AF.INET => {
            return try std.net.Address.parseIp4("0.0.0.0", 5353);
        },
        std.os.AF.INET6 => {
            return try std.net.Address.parseIp6("::", 5353);
        },
        else => {
            return error.UnkownAddressFamily;
        },
    }
}
