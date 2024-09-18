const socket = @import("socket.zig");
const dns = @import("dns.zig");
const dns_sd = @import("dns_sd.zig");
const nameservers = @import("nameservers.zig");

pub usingnamespace nameservers;
pub usingnamespace socket;
pub usingnamespace dns;
pub usingnamespace dns_sd;

test {
    _ = socket;
    _ = dns;
    _ = dns_sd;
    _ = nameservers;
}
