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

        var socket = try udp.Socket.init(bind_address);
        defer socket.deinit();

        try udp.setTimeout(socket.handle);
        try udp.enableReuse(socket.handle);

        try socket.bind();

        try udp.addMembership(socket.handle, group_address);
        try udp.setupMulticast(socket.handle, group_address);

        _ = try io.writeQuery(socket.writer(), question);
        try socket.sendTo(group_address);

        var i: u8 = 0;
        const limit: u8 = 55;
        while (i < limit) : (i += 1) {
            try socket.receive();
            const msg = io.readMessage(allocator, socket.reader()) catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        break;
                    },
                    else => {
                        return err;
                    },
                }
            };

            if (msg.header.flags.query_or_reply == .reply) {
                for (msg.records) |r| {
                    if (std.ascii.eqlIgnoreCase(r.name, question.name)) {
                        return msg;
                    }
                }
            }

            msg.deinit();
        }
    }

    return error.NoAnswer;
}

pub fn get_servers() [2][2]std.net.Address {
    return [2][2]std.net.Address{
        [2]std.net.Address{
            std.net.Address.parseIp("::", 5353) catch unreachable,
            //std.net.Address.parseIp("ff02::fb", 5353) catch unreachable,
            std.net.Address.parseIp("ff02::fb", 5353) catch unreachable,
        },
        [2]std.net.Address{
            //std.net.Address.parseIp("0.0.0.0", 5353) catch unreachable,
            std.net.Address.parseIp("224.0.0.251", 5353) catch unreachable,
            std.net.Address.parseIp("224.0.0.251", 5353) catch unreachable,
        },
    };
}

pub fn queryBKP(allocator: std.mem.Allocator, question: data.Question, _: dns.Options) !data.Message {
    const servers = get_servers();

    for (servers) |addresses| {
        const bind_address = addresses[0];
        const group_address = addresses[1];
        log.info("Trying address: Bind: {any}, MC: {any}", .{ bind_address, group_address });

        var socket_in = try udp.Socket.init(bind_address);
        defer socket_in.deinit();

        //try setTimeout(sock_in);
        try udp.enableReuse(socket_in.handle);
        try socket_in.bind();
        try udp.addMembership(socket_in.handle, group_address);
        //try udp.setupMulticast(socket_in.handle, group_address);

        var id: u16 = 0;

        {
            var socket_out = try udp.Socket.init(group_address);
            defer socket_out.deinit();

            //try udp.setTimeout(socket_out.handle);
            //try socket_out.connect();
            try udp.setupMulticast(socket_out.handle, group_address);
            //try udp.addMembership(socket_out.handle, group_address);

            id = try io.writeQuery(socket_out.writer(), question, false);
            try socket_out.send();
        }

        var i: u8 = 0;
        const limit: u8 = 55;
        while (i < limit) : (i += 1) {
            try socket_in.receive();
            const msg = try io.readMessage(allocator, socket_in.reader());
            if (msg.header.ID == id and msg.header.flags.query_or_reply == .reply) {
                return msg;
            } else {
                msg.deinit();
            }
        }
    }

    return error.NoAnswer;
}
