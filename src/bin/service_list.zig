const std = @import("std");
const os = std.os;

const dns = @import("dns");

const log = std.log.scoped(.discover_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    const result = try dns.listLocalServices(allocator);
    defer result.deinit();

    for (result.services) |service| {
        log.info("Service found: {s}", .{service});

        const service_list = try dns.listDetailedServices(allocator, service);
        defer service_list.deinit();
        for (service_list.services) |srv| {
            log.info("=> Name: {s}", .{srv.name});
            log.info("=> Host: {s}:{d}", .{ srv.host, srv.port });
            log.info("=> Addresses: {d}", .{srv.addresses.len});
            for (srv.addresses) |addr| {
                log.info("==> {any}", .{addr});
            }
            log.info("=> TXT: {d}", .{srv.txt.len});
            for (srv.txt) |txt| {
                log.info("==> {s}", .{txt});
            }
        }
    }
}
