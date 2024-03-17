const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

pub const Socket = struct {
    address: std.net.Address,
    handle: std.os.socket_t,

    buffer: [512]u8 = undefined,
    pos: usize = 0,
    len: usize = 0,

    pub fn init(address: std.net.Address) !@This() {
        const handle = try std.os.socket(address.any.family, std.os.SOCK.DGRAM | std.os.SOCK.CLOEXEC, 0);
        return @This(){
            .address = address,
            .handle = handle,
        };
    }

    pub fn deinit(self: *@This()) void {
        std.os.close(self.handle);
    }

    pub fn bind(self: *@This()) !void {
        try std.os.bind(self.handle, &self.address.any, self.address.getOsSockLen());
    }

    pub fn connect(self: *@This()) !void {
        try std.os.connect(self.handle, &self.address.any, self.address.getOsSockLen());
    }

    pub fn reset(self: *@This()) void {
        self.pos = 0;
        self.len = 0;
    }

    pub fn send(self: *@This()) !void {
        const bytes = self.buffer[0..self.len];
        _ = try std.os.send(self.handle, bytes, 0);
        self.len = 0;
    }

    pub fn writer(self: *@This()) std.io.AnyWriter {
        return .{
            .context = self,
            .writeFn = write,
        };
    }

    pub fn write(context: *const anyopaque, buffer: []const u8) anyerror!usize {
        const self: *@This() = @constCast(@ptrCast(@alignCast(context)));

        if (self.len == self.buffer.len) {
            return 0;
        }

        const len = @min(buffer.len, self.buffer.len - self.len);
        const end = @min(len, self.buffer.len) + self.len;
        std.mem.copyForwards(u8, self.buffer[self.len..end], buffer[0..len]);

        self.len += len;

        return len;
    }

    pub fn reader(self: *@This()) std.io.AnyReader {
        return .{
            .context = self,
            .readFn = read,
        };
    }

    pub fn receive(self: *@This()) !void {
        const len = try std.os.recv(self.handle, &self.buffer, 0);
        self.pos = 0;
        self.len = len;
    }

    pub fn read(context: *const anyopaque, buffer: []u8) anyerror!usize {
        const self: *@This() = @constCast(@ptrCast(@alignCast(context)));

        if (self.pos == self.len) {
            return 0;
        }

        const len = @min(buffer.len, self.len - self.pos);
        const end = @min(len, self.len) + self.pos;
        std.mem.copyForwards(u8, buffer, self.buffer[self.pos..end]);

        self.pos += len;

        return len;
    }
};

test "Socket read and write" {
    const addr = try std.net.Address.parseIp("127.0.0.1", 5353);
    var socket = try Socket.init(addr);
    defer socket.deinit();

    const writer = socket.writer();

    const data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };

    var len = try writer.write(data[0..5]);
    try testing.expectEqual(len, 5);
    len = try writer.write(data[5..10]);
    try testing.expectEqual(len, 5);
    len = try writer.write(data[10..]);
    try testing.expectEqual(len, 2);

    const reader = socket.reader();

    const d0 = [_]u8{ 1, 2, 3, 4, 5 };
    const d1 = [_]u8{ 6, 7, 8, 9, 10 };
    const d2 = [_]u8{ 11, 12 };

    var buffer: [5]u8 = undefined;
    len = try reader.read(&buffer);
    try testing.expectEqual(len, 5);
    try testing.expectEqualSlices(u8, &d0, buffer[0..len]);

    len = try reader.read(&buffer);
    try testing.expectEqual(len, 5);
    try testing.expectEqualSlices(u8, &d1, buffer[0..len]);

    len = try reader.read(&buffer);
    try testing.expectEqual(len, 2);
    try testing.expectEqualSlices(u8, &d2, buffer[0..len]);

    len = try reader.read(&buffer);
    try testing.expectEqual(len, 0);
}

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
