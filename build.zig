const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dns = b.addModule("dns", .{
        .root_source_file = b.path("src/dns/root.zig"),
    });

    {
        const exe = b.addExecutable(.{
            .name = "demo",
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/bin/demo.zig"),
            .link_libc = true,
        });
        exe.root_module.addImport("dns", dns);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run", "Run example");
        run_step.dependOn(&run_cmd.step);
    }

    {
        const tests = b.addTest(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/dns/root.zig"),
            .link_libc = true,
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
            .link_libc = true,
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
