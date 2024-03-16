const std = @import("std");

const io = @import("io.zig");
const data = @import("data.zig");
const udp = @import("udp.zig");
const dns = @import("dns.zig");

const log = std.log.scoped(.with_dns);

pub fn query(allocator: std.mem.Allocator, question: data.Question, _: dns.Options) !data.Message {
    const servers = get_servers();

    for (servers) |addresses| {
        const bind_address = addresses[0];
        const group_address = addresses[1];
        log.info("Trying address: Bind: {any}, MC: {any}", .{ bind_address, group_address });

        const sock_in = try std.os.socket(bind_address.any.family, std.os.SOCK.DGRAM, 0);
        defer std.os.close(sock_in);

        var socket_in = udp.Socket.init(allocator, sock_in);
        defer socket_in.deinit();

        {
            //try setTimeout(sock_in);
            try udp.enableReuse(sock_in);
            try std.os.bind(sock_in, &bind_address.any, bind_address.getOsSockLen());
            try udp.addMembership(sock_in, bind_address);
        }

        var id: u16 = 0;

        {
            const sock_out = try std.os.socket(group_address.any.family, std.os.SOCK.DGRAM, 0);
            defer std.os.close(sock_out);

            var socket_out = udp.Socket.init(allocator, sock_out);
            defer socket_out.deinit();

            try udp.setTimeout(sock_out);
            //try setupMulticast(sock_out, group_address);
            try std.os.connect(sock_out, &group_address.any, group_address.getOsSockLen());

            id = try io.writeQuery(socket_out.writer(), question);
            try socket_out.flush();
        }

        while (true) {
            const reply = try io.readMessage(allocator, socket_in.reader());
            if (reply.header.ID != id) {
                continue;
            }
            log.info("Reply: {any}", .{reply});
            //return reply;
        }
    }

    return error.NoAnswer;
}

pub fn get_servers() [2][2]std.net.Address {
    return [2][2]std.net.Address{
        [2]std.net.Address{
            std.net.Address.parseIp("224.0.0.251", 5353) catch unreachable,
            std.net.Address.parseIp("224.0.0.251", 5353) catch unreachable,
            //std.net.Address.parseIp("0.0.0.0", 5353) catch unreachable,
        },
        [2]std.net.Address{
            std.net.Address.parseIp("::", 5353) catch unreachable,
            std.net.Address.parseIp("ff02::fb", 5353) catch unreachable,
        },
    };
}
