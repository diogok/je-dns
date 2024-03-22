const std = @import("std");
const builtin = @import("builtin");

const testing = std.testing;

const io = @import("io.zig");
const data = @import("data.zig");
const udp = @import("udp.zig");
const nsservers = @import("nsservers.zig");

const log = std.log.scoped(.with_dns);

pub const Options = struct {};

pub fn query(allocator: std.mem.Allocator, question: data.Question, options: Options) !Result {
    if (isLocal(question.name)) {
        return try queryMDNS(allocator, question, options);
    } else {
        return try queryDNS(allocator, question, options);
    }
}

fn queryDNS(allocator: std.mem.Allocator, question: data.Question, _: Options) !Result {
    var questions = try allocator.alloc(data.Question, 1);
    errdefer allocator.free(questions);
    questions[0] = question;

    const message = data.Message{
        .header = .{
            .ID = data.mkid(),
            .number_of_questions = 1,
            .flags = .{
                .recursion_available = true,
                .recursion_desired = true,
            },
        },
        .questions = questions,
    };

    const servers = try nsservers.getDNSServers(allocator);
    defer allocator.free(servers);
    for (servers) |address| {
        log.debug("Trying address: {any}", .{address});

        var socket = try udp.Socket.init(address);
        defer socket.deinit();

        try udp.setTimeout(socket.handle);
        try socket.connect();
        log.info("Connected to {any}", .{address});

        try io.writeMessage(socket.writer(), message);

        try socket.send();
        try socket.receive();

        const reply = try io.readMessage(allocator, socket.reader());

        var replies = try allocator.alloc(data.Message, 1);
        replies[0] = reply;
        return Result{
            .allocator = allocator,
            .query = message,
            .replies = replies,
        };
    }

    const result = Result{
        .allocator = allocator,
        .query = message,
        .replies = &[_]data.Message{},
    };
    return result;
}

fn queryMDNS(allocator: std.mem.Allocator, question: data.Question, _: Options) !Result {
    var replies = std.ArrayList(data.Message).init(allocator);
    defer replies.deinit();

    var questions = try allocator.alloc(data.Question, 1);
    errdefer allocator.free(questions);
    questions[0] = question;

    var message = data.Message{};
    message.questions = questions;
    message.header.ID = data.mkid();
    message.header.number_of_questions = 1;

    const ip6_any = try std.net.Address.parseIp("::", 5353);
    const ip6_mdns = try std.net.Address.parseIp("ff02::fb", 5353);

    var ip6_socket = try udp.Socket.init(ip6_any);
    defer ip6_socket.deinit();

    const ip4_mdns = try std.net.Address.parseIp("224.0.0.251", 5353);

    var ip4_socket = try udp.Socket.init(ip4_mdns);
    defer ip4_socket.deinit();

    {
        try udp.setTimeout(ip6_socket.handle);
        try udp.setTimeout(ip4_socket.handle);

        try udp.enableReuse(ip6_socket.handle);
        try udp.enableReuse(ip4_socket.handle);

        try ip6_socket.bind();
        try ip4_socket.bind();

        try udp.addMembership(ip6_socket.handle, ip4_mdns);
        try udp.addMembership(ip4_socket.handle, ip4_mdns);

        try udp.setupMulticast(ip6_socket.handle, ip6_mdns);
        try udp.setupMulticast(ip4_socket.handle, ip4_mdns);
    }

    try io.writeMessage(ip6_socket.writer(), message);
    try ip6_socket.sendTo(ip6_mdns);

    try io.writeMessage(ip4_socket.writer(), message);
    try ip4_socket.sendTo(ip4_mdns);

    var i: u8 = 0;
    const attempts: u8 = 8;
    const sockets = [_]*udp.Socket{ &ip6_socket, &ip4_socket };
    while (i < attempts) : (i += 1) {
        for (sockets) |socket| {
            socket.receive() catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        continue;
                    },
                    else => {
                        return err;
                    },
                }
            };

            const msg = io.readMessage(allocator, socket.reader()) catch |err| {
                switch (err) {
                    error.EndOfStream => {
                        log.warn("Skipping message due to EndOfStream.", .{});
                        continue;
                    },
                    else => {
                        return err;
                    },
                }
            };

            var keep = false;
            if (msg.header.flags.query_or_reply == .reply) {
                for (msg.records) |r| {
                    if (std.ascii.eqlIgnoreCase(r.name, question.name)) {
                        keep = true;
                        break;
                    }
                }
            }

            if (keep) {
                try replies.append(msg);
            } else {
                msg.deinit(allocator);
            }
        }
    }

    const result = Result{
        .allocator = allocator,
        .query = message,
        .replies = try replies.toOwnedSlice(),
    };
    return result;
}

fn isLocal(address: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(address, ".local") or std.ascii.endsWithIgnoreCase(address, ".local.");
}

pub const Result = struct {
    allocator: std.mem.Allocator,

    query: data.Message,
    replies: []data.Message,

    pub fn deinit(self: @This()) void {
        //self.query.deinit(self.allocator);
        self.allocator.free(self.query.questions);
        for (self.replies) |r| {
            r.deinit(self.allocator);
        }
        self.allocator.free(self.replies);
    }
};

pub const logMessage = io.logMessage;

pub fn logResult(logfn: anytype, result: Result) void {
    logMessage(logfn, result.query);
    for (result.replies) |r| {
        logMessage(logfn, r);
    }
}
