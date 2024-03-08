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
        var writer = stream.writer();

        try dns.writeQuery(&writer, "diogok.net");
        const req = stream.getWritten();
        log.info("Request, kinda: ({d}) {b}", .{ req.len, req });
        _ = try os.send(sock, req, 0);
    }

    log.info("Sent request", .{});
    std.time.sleep(3 * 1000 * 1000 * 1000);
    log.info("Lets see if there is answer", .{});

    {
        var buffer: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();
        var reader = stream.reader();

        var buffer0: [512]u8 = undefined;
        const recvd = try os.recv(sock, &buffer0, 0);
        log.info("Received: {d}", .{recvd});
        const writd = try writer.write(buffer0[0..recvd]);
        log.info("Received: {d}", .{writd});

        stream.reset();

        const records = try dns.read_response(allocator, &reader);
        defer {
            for (records) |record| {
                record.deinit();
            }
            allocator.free(records);
        }
        log.info("Records: {any}", .{records});
    }

    os.close(sock);
}

fn read_age() !void {
    const out = std.io.getStdOut();
    const writer = out.writer();

    const in = std.io.getStdIn();
    const reader = in.reader();

    try writer.print("Hello!\n", .{});

    var buffer: [1024]u8 = undefined;
    var response_stream = std.io.fixedBufferStream(&buffer);
    const response_writer = response_stream.writer();

    try reader.streamUntilDelimiter(response_writer, '\n', 3);

    const age = response_stream.getWritten();
    const age_n = try std.fmt.parseInt(u8, age, 10);

    try writer.print("You age is: {d}.\n", .{age_n});
}
