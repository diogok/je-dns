const std = @import("std");
const builtin = @import("builtin");

pub const Stream = std.io.FixedBufferStream([]u8);

pub const Options = struct {
    socket_type: enum(u32) {
        UDP = std.posix.SOCK.DGRAM,
        //TCP = std.posix.SOCK.STREAM,
    } = .UDP,
    timeout_in_millis: i32 = 1000,
    initalize: bool = true,
};

pub const Socket = struct {
    address: std.net.Address,
    handle: std.posix.socket_t,

    recv_buffer: [512]u8 = undefined,
    send_buffer: [512]u8 = undefined,
    send_stream: ?Stream,

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
        };

        const send_stream = std.io.fixedBufferStream(&self.send_buffer);
        self.send_stream = send_stream;

        if (options.initalize) {
            try self.timeout(options.timeout_in_millis);
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
        const len = try std.posix.recv(self.handle, &self.recv_buffer, 0);
        return std.io.fixedBufferStream(self.recv_buffer[0..len]);
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

    pub fn timeout(self: *@This(), millis: i32) !void {
        try setTimeout(self.handle, millis);
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

pub fn setTimeout(fd: std.posix.socket_t, millis: i32) !void {
    const micros: i32 = millis * 1000;
    if (micros > 0) {
        var timeout: std.posix.timeval = undefined;
        timeout.tv_sec = @as(c_long, @intCast(@divTrunc(micros, 1000000)));
        timeout.tv_usec = @as(c_long, @intCast(@mod(micros, 1000000)));
        try std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.toBytes(timeout)[0..],
        );
        try std.posix.setsockopt(
            fd,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.toBytes(timeout)[0..],
        );
    }
}

pub fn enableReuse(sock: std.posix.socket_t) !void {
    if (builtin.os.tag != .windows) {
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
    // TODO: win vs linux
    switch (address.any.family) {
        std.posix.AF.INET => {
            const any = try getAny(address);
            try std.posix.setsockopt(
                sock,
                std.os.SOL.IP,
                std.os.system.IP.MULTICAST_IF,
                std.mem.asBytes(&any.in.sa.addr),
            );
            try std.posix.setsockopt(
                sock,
                std.posix.SOL.IP,
                std.posix.system.IP.MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.posix.setsockopt(
                sock,
                std.posix.SOL.IP,
                std.posix.system.IP.MULTICAST_TTL,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        },
        std.posix.AF.INET6 => {
            try std.posix.setsockopt(
                sock,
                std.posix.SOL.IPV6,
                std.posix.system.IPV6.MULTICAST_IF,
                &std.mem.toBytes(@as(c_int, 0)),
            );
            try std.posix.setsockopt(
                sock,
                std.posix.SOL.IPV6,
                std.posix.system.IPV6.MULTICAST_HOPS,
                &std.mem.toBytes(@as(c_int, 1)),
            );
            try std.posix.setsockopt(
                sock,
                std.posix.SOL.IPV6,
                std.posix.system.IPV6.MULTICAST_LOOP,
                &std.mem.toBytes(@as(c_int, 1)),
            );
        },
        else => {},
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
                std.posix.SOL.IP,
                std.posix.linux.IP.ADD_MEMBERSHIP,
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
                std.posix.SOL.IPV6,
                std.posix.system.IPV6.ADD_MEMBERSHIP,
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
