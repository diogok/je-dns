const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const io = @import("io.zig");
const data = @import("data.zig");
const udp = @import("udp.zig");
const nsservers = @import("nsservers.zig");

const log = std.log.scoped(.with_dns);

pub const Options = struct {};

pub fn query(allocator: std.mem.Allocator, question: data.Question, options: Options) !data.Message {
    if (isLocal(question.name)) {
        return try queryMDNS(allocator, question, options);
    } else {
        return try queryDNS(allocator, question, options);
    }
}

fn queryDNS(allocator: std.mem.Allocator, question: data.Question, _: Options) !data.Message {
    const servers = try nsservers.getDNSServers(allocator);
    defer allocator.free(servers);

    for (servers) |address| {
        log.info("Trying address: {any}", .{address});

        var socket = try udp.Socket.init(address);
        defer socket.deinit();

        try udp.setTimeout(socket.handle);
        try socket.connect();
        log.info("Connected to {any}", .{address});

        _ = try io.writeQuery(socket.writer(), question);

        try socket.send();
        try socket.receive();

        const reply = try io.readMessage(allocator, socket.reader());
        if (reply.records.len > 0) {
            return reply;
        } else {
            reply.deinit();
        }
    }

    return error.NoAnswer;
}

fn queryMDNS(allocator: std.mem.Allocator, question: data.Question, _: Options) !data.Message {
    const servers = nsservers.getMDNSServers();

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
        try socket.sendTo();

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

fn isLocal(address: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(address, ".local") or std.ascii.endsWithIgnoreCase(address, ".local.");
}
