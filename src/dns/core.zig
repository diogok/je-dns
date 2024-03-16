const std = @import("std");

const data = @import("data.zig");
const dns = @import("dns.zig");
const mdns = @import("mdns.zig");

pub const Options = dns.Options;

pub fn query(allocator: std.mem.Allocator, question: data.Question, options: Options) !data.Message {
    if (std.ascii.endsWithIgnoreCase(question.name, ".local")) {
        return try mdns.query(allocator, question, options);
    } else {
        return try dns.query(allocator, question, options);
    }
}

test "all" {
    _ = @import("io.zig");
    _ = @import("data.zig");
    _ = @import("dns.zig");
    _ = @import("mdns.zig");
    _ = @import("udp.zig");
}
