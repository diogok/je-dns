const std = @import("std");
const builtin = @import("builtin");

const ByteArrayList = std.ArrayList(u8);
const ByteWriter = ByteArrayList.Writer;

pub const Socket = struct {
    allocator: std.mem.Allocator,

    address: std.net.Address,
    handle: std.os.socket_t,

    write_data: ByteArrayList,
    read_data: ByteArrayList,

    read_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !@This() {
        const handle = try std.os.socket(address.any.family, std.os.SOCK.DGRAM | std.os.SOCK.CLOEXEC, 0);

        const write_data = ByteArrayList.init(allocator);
        const read_data = ByteArrayList.init(allocator);

        return @This(){
            .allocator = allocator,

            .address = address,
            .handle = handle,

            .write_data = write_data,
            .read_data = read_data,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.write_data.deinit();
        self.read_data.deinit();
        std.os.close(self.handle);
    }

    pub fn bind(self: *@This()) !void {
        try std.os.bind(self.handle, &self.address.any, self.address.getOsSockLen());
    }

    pub fn connect(self: *@This()) !void {
        try std.os.connect(self.handle, &self.address.any, self.address.getOsSockLen());
    }

    pub fn flush(self: *@This()) !void {
        const bytes = try self.write_data.toOwnedSlice();
        defer self.allocator.free(bytes);
        _ = try std.os.send(self.handle, bytes[0..28], 0);
    }

    pub fn writer(self: *@This()) ByteWriter {
        return self.write_data.writer();
    }

    pub fn reader(self: *@This()) std.io.AnyReader {
        return .{
            .context = self,
            .readFn = read,
        };
    }

    pub fn read(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const self: *@This() = @constCast(@ptrCast(@alignCast(context)));
        return try std.os.recv(self.handle, buffer, 0);
    }
};

pub fn setTimeout(fd: std.os.socket_t) !void {
    const micros: i32 = 1000000;
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
            //const any = std.net.Address.parseIp4("224.0.0.251", 5353) catch unreachable;
            //try std.os.setsockopt(
            //    sock,
            //    std.os.SOL.IP,
            //    std.os.system.IP.MULTICAST_IF,
            //    std.mem.asBytes(&any.in.sa.addr),
            //);
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
            const any = std.net.Address.parseIp4("0.0.0.0", 5353) catch unreachable;
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
            //const mdnsAddr = std.net.Address.parseIp6("ff02::fb", 5353) catch unreachable;
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
