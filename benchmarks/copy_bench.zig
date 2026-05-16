//! Light-weight benchmark comparing bulk-insert strategies.
//!
//! Runs three sizes (1k / 10k / 100k rows) against a local PG and prints
//! wall-clock duration + rows/sec for each strategy:
//!   1. exec_in_tx  - BEGIN, parameterised INSERT per row, COMMIT
//!   2. copy_into   - conn.copyIntoTable (binary COPY FROM STDIN)
//!
//! Build & run (Release is important, Debug will skew everything):
//!   zig build bench -Doptimize=ReleaseFast
//!
//! Connection defaults: 127.0.0.1:5432, user=postgres, db=postgres, trust auth
//! (matches tests/run-pg.sh). Override via environment variables PGHOST,
//! PGPORT, PGUSER, PGDATABASE, PGPASSWORD.

const std = @import("std");
const pg = @import("pg");

const Row = struct {
    id: i32,
    name: []const u8,
    ts: i64,
};

const SIZES = [_]usize{ 1_000, 10_000, 100_000 };

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try readEnvConfig(allocator);
    defer cfg.deinit(allocator);

    // BENCH_COPY_ONLY=1 skips the (slow) exec_in_tx baseline so the
    // binary can be wrapped by hyperfine alongside the pgx / rust-postgres
    // benches (which only measure COPY).
    const copy_only = getenv("BENCH_COPY_ONLY") != null;

    var conn = try pg.Conn.openAndAuth(allocator, cfg.connect, cfg.auth);
    defer conn.deinit();

    try setupTable(&conn);
    defer dropTable(&conn) catch {};

    if (!copy_only) {
        std.debug.print(
            "bench: pg.zig COPY vs INSERT-in-tx  (3 columns: int4, text, int8)\n",
            .{},
        );
        std.debug.print(
            "{s:<12} {s:<16} {s:>12} {s:>14} {s:>10}\n",
            .{ "size", "strategy", "duration", "rows/sec", "relative" },
        );
        std.debug.print("{s}\n", .{"-" ** 70});
    }

    for (SIZES) |n| {
        const rows = try buildRows(allocator, n);
        defer allocator.free(rows);

        const copy_ns = try runCopy(&conn, rows);
        if (copy_only) {
            // CSV-friendly single-line format for downstream tools.
            const ms = @as(f64, @floatFromInt(copy_ns)) / std.time.ns_per_ms;
            const rps = @as(f64, @floatFromInt(n)) / (@as(f64, @floatFromInt(copy_ns)) / std.time.ns_per_s);
            std.debug.print("pg.zig,{d},{d:.3},{d:.0}\n", .{ n, ms, rps });
            continue;
        }

        // Full comparison mode: also run the slow INSERT-in-tx baseline.
        const insert_ns = try runInsertInTx(&conn, rows);
        reportRow(n, "exec_in_tx", insert_ns, 1.0);
        reportRow(n, "copy_into", copy_ns, @as(f64, @floatFromInt(insert_ns)) / @as(f64, @floatFromInt(copy_ns)));
        std.debug.print("\n", .{});
    }
}

// ---- strategies -------------------------------------------------------------

fn runInsertInTx(conn: *pg.Conn, rows: []const Row) !u64 {
    try truncate(conn);

    const start = nowNs();
    try conn.begin();
    errdefer conn.rollback() catch {};
    for (rows) |r| {
        _ = try conn.exec(
            "insert into bench_copy (id, name, ts) values ($1, $2, $3)",
            .{ r.id, r.name, r.ts },
        );
    }
    try conn.commit();
    return @intCast(nowNs() - start);
}

fn runCopy(conn: *pg.Conn, rows: []const Row) !u64 {
    try truncate(conn);

    const start = nowNs();
    const n = try conn.copyIntoTable("bench_copy", rows);
    std.debug.assert(n == @as(i64, @intCast(rows.len)));
    return @intCast(nowNs() - start);
}

// ---- helpers ----------------------------------------------------------------

fn setupTable(conn: *pg.Conn) !void {
    _ = try conn.exec("drop table if exists bench_copy", .{});
    _ = try conn.exec(
        "create table bench_copy (id int4 not null, name text not null, ts int8 not null)",
        .{},
    );
}

fn dropTable(conn: *pg.Conn) !void {
    _ = try conn.exec("drop table if exists bench_copy", .{});
}

fn truncate(conn: *pg.Conn) !void {
    _ = try conn.exec("truncate table bench_copy", .{});
}

fn buildRows(allocator: std.mem.Allocator, n: usize) ![]Row {
    const rows = try allocator.alloc(Row, n);
    // Names share a small pool of static strings so we don't measure
    // per-row allocation time. Representative enough for a mix of short
    // and medium-length text columns.
    const names = [_][]const u8{
        "alice",                                "bob",       "carol", "daniel",
        "ellen",                                "francesco", "gina",  "hiroshi",
        "ingrid",                               "junpei",    "kenji", "louisa",
        "maribel",                              "natalia",   "ogawa", "priscilla",
        "some-longer-name-just-to-vary-widths", "short",
    };
    for (rows, 0..) |*r, i| {
        r.* = .{
            .id = @intCast(i),
            .name = names[i % names.len],
            .ts = @as(i64, 1_700_000_000) + @as(i64, @intCast(i)),
        };
    }
    return rows;
}

fn reportRow(size: usize, label: []const u8, ns: u64, relative: f64) void {
    const secs = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    const rows_per_sec = @as(f64, @floatFromInt(size)) / secs;
    const duration_ms = @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    std.debug.print(
        "{d:<12} {s:<16} {d:>9.2} ms {d:>14.0} {d:>9.2}x\n",
        .{ size, label, duration_ms, rows_per_sec, relative },
    );
}

fn nowNs() i96 {
    return std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .awake).toNanoseconds();
}

fn getenv(key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry_z| : (i += 1) {
        const entry = std.mem.span(entry_z);
        if (entry.len > key.len and entry[key.len] == '=' and std.mem.eql(u8, entry[0..key.len], key)) {
            return entry[key.len + 1 ..];
        }
    }
    return null;
}

// ---- connection config from env --------------------------------------------

const Config = struct {
    connect: pg.Conn.Opts,
    auth: pg.Conn.AuthOpts,
    host_buf: ?[]u8,
    user_buf: ?[]u8,
    db_buf: ?[]u8,
    pass_buf: ?[]u8,

    fn deinit(self: Config, allocator: std.mem.Allocator) void {
        if (self.host_buf) |b| allocator.free(b);
        if (self.user_buf) |b| allocator.free(b);
        if (self.db_buf) |b| allocator.free(b);
        if (self.pass_buf) |b| allocator.free(b);
    }
};

fn readEnvConfig(allocator: std.mem.Allocator) !Config {
    const host = getenv("PGHOST");
    const user = getenv("PGUSER") orelse "postgres";
    const db = getenv("PGDATABASE") orelse "postgres";
    const pass = getenv("PGPASSWORD");

    const port: u16 = if (getenv("PGPORT")) |p|
        std.fmt.parseInt(u16, p, 10) catch 5432
    else
        5432;

    const host_buf = if (host) |h| try allocator.dupe(u8, h) else null;
    const user_buf = try allocator.dupe(u8, user);
    const db_buf = try allocator.dupe(u8, db);
    const pass_buf = if (pass) |p| try allocator.dupe(u8, p) else null;

    return .{
        .connect = .{
            .host = host_buf orelse "127.0.0.1",
            .port = port,
        },
        .auth = .{
            .username = user_buf,
            .database = db_buf,
            .password = pass_buf,
            .timeout = 10_000,
        },
        .host_buf = host_buf,
        .user_buf = user_buf,
        .db_buf = db_buf,
        .pass_buf = pass_buf,
    };
}
