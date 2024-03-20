const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dns = b.addModule("dns", .{ .root_source_file = .{ .path = "src/dns/dns.zig" } });

    {
        const tests = b.addTest(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .path = "src/dns/dns.zig" },
        });

        const run_tests = b.addRunArtifact(tests);
        const run_test_step = b.step("test", "Run tests");
        run_test_step.dependOn(&run_tests.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "example",
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .path = "src/bin/example.zig" },
            .link_libc = target.result.os.tag == .windows,
        });
        exe.root_module.addImport("dns", dns);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run", "Run example");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "dns-query",
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .path = "src/bin/dns_query.zig" },
            .link_libc = target.result.os.tag == .windows,
        });
        exe.root_module.addImport("dns", dns);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run-query", "Run query");
        run_step.dependOn(&run_cmd.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    {
        const exe = b.addExecutable(.{
            .name = "service-list",
            .target = target,
            .optimize = optimize,
            .root_source_file = .{ .path = "src/bin/service_list.zig" },
            .link_libc = target.result.os.tag == .windows,
        });
        exe.root_module.addImport("dns", dns);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run-service-list", "Run service list");
        run_step.dependOn(&run_cmd.step);
    }
}
