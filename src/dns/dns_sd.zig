const std = @import("std");
const dns = @import("dns.zig");
const net = @import("socket.zig");

pub const local_services_query = "_services._dns-sd._udp.local";
pub const resource_type: dns.ResourceType = .PTR;

pub const Announcer = struct {
    allocator: std.mem.Allocator,
    client: *dns.DNSClient,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !@This() {
        const client = try allocator.create(dns.DNSClient);
        client.* = dns.DNSClient.init(allocator, .{});
        try client.connect(dns.isLocal(name));

        return @This(){
            .allocator = allocator,
            .client = client,
            .name = name,
        };
    }

    pub fn deinit(self: *@This()) void {
        defer self.client.deinit();
    }

    pub fn handle(self: *@This()) !void {
        var is_query = false;
        var id: u16 = 0;
        while (try self.client.next()) |next| {
            switch (next) {
                .start_message => {},
                .end_message => {
                    return;
                },
                .header => |h| {
                    is_query = h.flags.query_or_reply == .query;
                    id = h.ID;
                },
                .question => |q| {
                    defer q.deinit(self.allocator);
                    if (is_query and q.resource_type == .PTR) {
                        try self.answer(id, q);
                    }
                },
                .record => |r| {
                    r.deinit(self.allocator);
                },
            }
        }
    }

    pub fn answer(self: *@This(), id: u16, q: dns.Question) !void {
        if (std.ascii.eqlIgnoreCase(q.name, "_services._dns-sd._udp.local")) {
            const response = dns.Message{
                .header = .{
                    .ID = id,
                    .flags = .{
                        .query_or_reply = .reply,
                        .authoritative_answer = true,
                    },
                    .number_of_answers = 1,
                },
                .records = &[_]dns.Record{
                    .{
                        .name = q.name,
                        .resource_type = q.resource_type,
                        .resource_class = .IN,
                        .ttl = 600,
                        .data = .{
                            .ptr = self.name,
                        },
                    },
                },
            };
            try self.client.send(response);
        } else if (std.ascii.eqlIgnoreCase(q.name, self.name)) {
            const response = dns.Message{
                .header = .{
                    .ID = id,
                    .flags = .{
                        .query_or_reply = .reply,
                        .authoritative_answer = true,
                    },
                    .number_of_answers = 1,
                },
                .records = &[_]dns.Record{
                    .{
                        .name = q.name,
                        .resource_type = q.resource_type,
                        .resource_class = .IN,
                        .ttl = 600,
                        .data = .{
                            .ptr = self.name,
                        },
                    },
                },
            };
            try self.client.send(response);
        }
    }
};
