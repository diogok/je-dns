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

        var socket_in = try udp.Socket.init(bind_address);
        defer socket_in.deinit();

        {
            //try setTimeout(sock_in);
            try udp.enableReuse(socket_in.handle);
            try socket_in.bind();
            try udp.addMembership(socket_in.handle, bind_address);
        }

        var id: u16 = 0;

        {
            var socket_out = try udp.Socket.init(group_address);
            defer socket_out.deinit();

            try udp.setTimeout(socket_out.handle);
            try socket_out.connect();
            //try setupMulticast(sock_out, group_address);

            id = try io.writeQuery(socket_out.writer(), question);
            try socket_out.send();
        }

        try socket_in.receive();
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
