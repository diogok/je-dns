const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dns = b.addModule("dns", .{ .root_source_file = b.path("src/dns/dns.zig") });
    const dns_sd = b.addModule("dns_sd", .{ .root_source_file = b.path("src/dns/dns_sd.zig") });
    _ = b.addModule("socket", .{ .root_source_file = b.path("src/dns/socket.zig") });
    _ = b.addModule("nameservers", .{ .root_source_file = b.path("src/dns/nameservers.zig") });

    const artifacts = [_][]const u8{
        "example",
        "service_list",
        "announcer",
    };

    for (artifacts[0..]) |artifact| {
        const exe = b.addExecutable(.{
            .name = artifact,
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(b.fmt("src/bin/{s}.zig", .{artifact})),
            .link_libc = target.result.os.tag == .windows, // used to get default dns addresses
        });
        exe.root_module.addImport("dns", dns);
        exe.root_module.addImport("dns_sd", dns_sd);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(b.fmt("run-{s}", .{artifact}), "Run example");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const tests = b.addTest(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/dns/root.zig"),
            .link_libc = target.result.os.tag == .windows, // used to get default dns addresses
        });

        const run_tests = b.addRunArtifact(tests);
        const run_test_step = b.step("test", "Run tests");
        run_test_step.dependOn(&run_tests.step);
    }

    {
        const docs = b.addObject(.{
            .name = "docs",
            .target = target,
            .optimize = .Debug,
            .root_source_file = b.path("src/dns/root.zig"),
        });

        const install_docs = b.addInstallDirectory(.{
            .source_dir = docs.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const docs_step = b.step("docs", "Install documentation");
        docs_step.dependOn(&install_docs.step);
    }
}
