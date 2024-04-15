const std = @import("std");
const dns = @import("dns.zig");
const net = @import("socket.zig");

pub fn listLocalServices(allocator: std.mem.Allocator) !ServiceList {
    var services = std.ArrayList([]const u8).init(allocator);

    var client = dns.DNSClient.init(allocator, .{});
    defer client.deinit();

    try client.query("_services._dns-sd._udp.local", .PTR);

    records: while (try client.nextRecord()) |record| {
        defer record.deinit(allocator);
        switch (record.resource_type) {
            .PTR => {
                for (services.items) |existing| {
                    if (std.mem.eql(u8, existing, record.data.ptr)) {
                        continue :records;
                    }
                }
                const service = try allocator.alloc(u8, record.data.ptr.len);
                std.mem.copyForwards(u8, service, record.data.ptr);
                try services.append(service);
            },
            else => {},
        }
    }

    return ServiceList{
        .allocator = allocator,
        .services = try services.toOwnedSlice(),
    };
}

pub const ServiceList = struct {
    allocator: std.mem.Allocator,
    services: [][]const u8,
    pub fn deinit(self: @This()) void {
        for (self.services) |service| {
            self.allocator.free(service);
        }
        self.allocator.free(self.services);
    }
};

pub fn listDetailedServices(allocator: std.mem.Allocator, qname: []const u8) !DetailedServiceList {
    var services = std.ArrayList(DetailedService).init(allocator);
    errdefer services.deinit();

    var client = dns.DNSClient.init(allocator, .{});
    defer client.deinit();

    try client.query(qname, .PTR);

    var name = std.ArrayList(u8).init(allocator);
    defer name.deinit();
    var port: u16 = 0;
    var host = std.ArrayList(u8).init(allocator);
    defer host.deinit();
    var addresses = std.ArrayList(std.net.Address).init(allocator);
    defer addresses.deinit();
    var txts = std.ArrayList([]const u8).init(allocator);
    defer {
        for (txts.items) |txt| {
            allocator.free(txt);
        }
        txts.deinit();
    }

    while (try client.next()) |next| {
        switch (next) {
            .start_message => {},
            .header => {},
            .question => |q| {
                q.deinit(allocator);
            },
            .record => |record| {
                defer record.deinit(allocator);
                switch (record.resource_type) {
                    .A, .AAAA => {
                        try addresses.append(record.data.ip);
                    },
                    .TXT => {
                        for (record.data.txt) |txt| {
                            const cp_txt = try allocator.alloc(u8, txt.len);
                            std.mem.copyForwards(u8, cp_txt, txt);
                            try txts.append(cp_txt);
                        }
                    },
                    .SRV => {
                        try host.appendSlice(record.data.srv.target);
                        port = record.data.srv.port;
                    },
                    .PTR => {
                        try name.appendSlice(record.data.ptr);
                    },
                    else => {},
                }
            },
            .end_message => {
                for (addresses.items) |*addr| {
                    addr.setPort(port);
                }

                try services.append(.{
                    .allocator = allocator,
                    .name = try name.toOwnedSlice(),
                    .host = try host.toOwnedSlice(),
                    .port = port,
                    .txt = try txts.toOwnedSlice(),
                    .addresses = try addresses.toOwnedSlice(),
                });
            },
        }
    }

    return DetailedServiceList{
        .allocator = allocator,
        .services = try services.toOwnedSlice(),
    };
}

pub const DetailedService = struct {
    allocator: std.mem.Allocator,

    name: []const u8,
    host: []const u8,
    port: u16,
    txt: [][]const u8,
    addresses: []std.net.Address,

    pub fn deinit(self: @This()) void {
        self.allocator.free(self.name);
        self.allocator.free(self.host);
        self.allocator.free(self.addresses);
        for (self.txt) |txt| {
            self.allocator.free(txt);
        }
        self.allocator.free(self.txt);
    }
};

pub const DetailedServiceList = struct {
    allocator: std.mem.Allocator,
    services: []DetailedService,

    pub fn deinit(self: @This()) void {
        for (self.services) |service| {
            service.deinit();
        }
        self.allocator.free(self.services);
    }
};

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
