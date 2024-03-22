const std = @import("std");
const core = @import("core.zig");

const log = std.log.scoped(.with_dns);

pub fn listLocalServices(allocator: std.mem.Allocator) !ServiceList {
    var services = std.ArrayList([]const u8).init(allocator);

    const result = try core.query(allocator, .{ .name = "_services._dns-sd._udp.local", .resource_type = .PTR }, .{});
    defer result.deinit();

    for (result.replies) |reply| {
        records: for (reply.records) |record| {
            for (services.items) |existing| {
                if (std.mem.eql(u8, existing, record.data.ptr)) {
                    continue :records;
                }
            }
            const service = try allocator.alloc(u8, record.data.ptr.len);
            std.mem.copyForwards(u8, service, record.data.ptr);
            try services.append(service);
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

    const result = try core.query(allocator, .{ .name = qname, .resource_type = .PTR }, .{});
    defer result.deinit();

    replies: for (result.replies) |reply| {
        const service_name = name_blk: {
            for (reply.records) |record| {
                if (std.ascii.eqlIgnoreCase(record.name, qname)) {
                    const srv_name = record.data.ptr;
                    for (services.items) |existing| {
                        if (std.mem.eql(u8, existing.name, srv_name)) {
                            continue :replies;
                        }
                    }

                    const cp_name = try allocator.alloc(u8, record.data.ptr.len);
                    std.mem.copyForwards(u8, cp_name, srv_name);
                    break :name_blk cp_name;
                }
            }
            break :replies;
        };

        var host = std.ArrayList(u8).init(allocator);
        var addresses = std.ArrayList(std.net.Address).init(allocator);
        var port: u16 = 0;
        var txts = std.ArrayList([]const u8).init(allocator);

        for (reply.additional_records) |record| {
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
                else => {},
            }
        }
        for (addresses.items) |*addr| {
            addr.setPort(port);
        }

        const service = DetailedService{
            .allocator = allocator,
            .name = service_name,
            .host = try host.toOwnedSlice(),
            .port = port,
            .addresses = try addresses.toOwnedSlice(),
            .txt = try txts.toOwnedSlice(),
        };
        try services.append(service);
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
