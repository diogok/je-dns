const std = @import("std");
const os = std.os;

const dns = @import("dns.zig");

const log = std.log.scoped(.with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const sock = try os.socket(os.AF.INET, os.SOCK.DGRAM | os.SOCK.CLOEXEC, 0);
    errdefer os.close(sock);

    //const addr = try std.net.Address.resolveIp("224.0.0.251", 5353);
    const addr = try std.net.Address.resolveIp("127.0.0.53", 53);
    try os.connect(sock, &addr.any, addr.getOsSockLen());
    log.info("Connected at least", .{});

    {
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        const writer = stream.writer();

        try dns.writeQuery(writer, "google.com", .A);
        const req = stream.getWritten();
        log.info("Request, kinda: ({d}) {b}", .{ req.len, req });
        _ = try os.send(sock, req[0..28], 0);
    }

    log.info("Sent request", .{});
    std.time.sleep(3 * 1000 * 1000 * 1000);
    log.info("Lets see if there is answer", .{});

    {
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();
        const reader = stream.reader();

        var buffer0: [512]u8 = undefined;
        const recvd = try os.recv(sock, &buffer0, 0);
        const written = try writer.write(buffer0[0..recvd]);
        log.info("Reply, kinda: ({d}) {b}", .{ written, buffer0[0..written] });

        stream.reset();

        const reply = try dns.read_reply(allocator, reader);
        defer reply.deinit();
        log.info("Reply: {any}", .{reply});
    }

    os.close(sock);
}
