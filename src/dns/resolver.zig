const std = @import("std");
const data = @import("data.zig");

const testing = std.testing;

const mDNSService = struct {
    name: []const u8,
    port: u16,
};

pub const Resolver = struct {
    services: []mDNSService,

    pub fn init(services: []mDNSService) @This() {
        return @This(){ .services = services };
    }

    pub fn query(self: @This(), q: []const u8, _: data.ResourceType) ResolverIterrator {
        return ResolverIterrator{
            .l = self.services,
            .q = q,
            .i = 0,
        };
    }
};

pub const ResolverIterrator = struct {
    l: []mDNSService,
    q: []const u8,
    i: usize = 0,

    pub fn nextAnswer(self: *@This()) ?data.Record {
        while (self.i < self.l.len) : (self.i += 1) {
            return data.Record{
                .name = mdns_services_query,
                .resource_class = .IN,
                .resource_type = .PTR,
                .data = .{
                    .ptr = self.l[self.i].name,
                },
            };
        }
        return null;
    }

    pub fn reset(self: *@This()) void {
        self.i = 0;
    }

    pub fn nextAdditional(_: *@This()) ?data.Record {
        return null;
    }
};

test "Resolver" {
    const my_services = [_]mDNSService{
        .{
            .name = "_http._tcp.local",
            .port = 8080,
        },
        .{
            .name = "_hello._udp.local",
            .port = 5432,
        },
    };

    const resolver = Resolver.init(my_services);
    {
        var iter = resolver.query(mdns_services_query, mdns_services_resource_type);

        const r0 = iter.nextAnswer();
        try testing.expectEqualStrings("_http._tcp.local", r0.?.data.PTR);
        const r1 = iter.next();
        try testing.expectEqualStrings("_hello._tcp.local", r1.?.data.PTR);
        const r2 = iter.next();
        try testing.expect(r2 == null);
    }
}

/// Query to find all local network services
pub const mdns_services_query = "_services._dns-sd._udp.local";
/// Resource Type for local network services
pub const mdns_services_resource_type: data.ResourceType = .PTR;
