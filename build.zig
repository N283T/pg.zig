const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // setup our dependencies
    const dep_opts = .{ .target = target, .optimize = optimize };

    // Expose this as a module that others can import
    const pg_module = b.addModule("pg", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/pg.zig"),
        .imports = &.{
            .{ .name = "buffer", .module = b.dependency("buffer", dep_opts).module("buffer") },
            .{ .name = "metrics", .module = b.dependency("metrics", dep_opts).module("metrics") },
        },
    });

    var openssl = false;
    const openssl_lib_name = b.option([]const u8, "openssl_lib_name", "");
    const openssl_lib_path = b.option(std.Build.LazyPath, "openssl_lib_path", "");
    const openssl_include_path = b.option(std.Build.LazyPath, "openssl_include_path", "");

    if (openssl_include_path) |p| {
        openssl = true;
        pg_module.addIncludePath(p);
    }
    if (openssl_lib_path) |p| {
        openssl = true;
        pg_module.addLibraryPath(p);
    }
    if (openssl_lib_name != null) {
        openssl = true;
    }

    if (openssl) {
        pg_module.linkSystemLibrary("crypto", .{});
        pg_module.linkSystemLibrary(openssl_lib_name orelse "ssl", .{});
        pg_module.link_libc = true;
    }

    var column_names = false;
    const column_names_opt = b.option(bool, "column_names", "");

    if (column_names_opt) |val| {
        column_names = val;
    }

    {
        const options = b.addOptions();
        options.addOption(bool, "openssl", openssl);
        options.addOption(bool, "column_names", column_names);
        pg_module.addOptions("config", options);
    }

    {
        // test step
        const lib_test = b.addTest(.{
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("src/pg.zig"),
                .imports = &.{
                    .{ .name = "buffer", .module = b.dependency("buffer", dep_opts).module("buffer") },
                    .{ .name = "metrics", .module = b.dependency("metrics", dep_opts).module("metrics") },
                },
            }),
            .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        });
        if (openssl_lib_path) |p|
            lib_test.addLibraryPath(p);
        if (openssl_include_path) |p|
            lib_test.addIncludePath(p);
        lib_test.linkSystemLibrary("crypto");
        lib_test.linkSystemLibrary("ssl");

        {
            const options = b.addOptions();
            options.addOption(bool, "openssl", true);
            options.addOption(bool, "column_names", false);
            lib_test.root_module.addOptions("config", options);
        }

        const run_test = b.addRunArtifact(lib_test);
        run_test.has_side_effects = true;

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_test.step);
    }

    {
        // bench step: build + run benchmarks/copy_bench.zig against the
        // local PG started via tests/run-pg.sh (or any PG reachable via
        // PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD). Meaningful only in
        // a release-mode build, e.g.:
        //   zig build bench -Doptimize=ReleaseFast
        const bench_exe = b.addExecutable(.{
            .name = "copy_bench",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .root_source_file = b.path("benchmarks/copy_bench.zig"),
                .imports = &.{
                    .{ .name = "pg", .module = pg_module },
                },
            }),
        });
        // Install the binary so external wrappers (bench_hyperfine.sh)
        // can invoke it from a known location without scraping the cache.
        b.installArtifact(bench_exe);

        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.has_side_effects = true;
        if (b.args) |args| run_bench.addArgs(args);

        const bench_step = b.step("bench", "Run COPY vs INSERT benchmark");
        bench_step.dependOn(&run_bench.step);
    }
}
