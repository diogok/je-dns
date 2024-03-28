const std = @import("std");
const dns_sd = @import("dns_sd");

const log = std.log.scoped(.announc_with_me);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    var announcer = try dns_sd.Announcer.init(allocator, "_my_service");
    defer announcer.deinit();

    while (true) {
        announcer.handle() catch continue;
    }
}
