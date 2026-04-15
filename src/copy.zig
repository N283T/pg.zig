const std = @import("std");
const lib = @import("lib.zig");
const Buffer = @import("buffer").Buffer;

const Allocator = std.mem.Allocator;
const Conn = lib.Conn;
const proto = lib.proto;
const types = lib.types;

pub const CopyOpts = struct {
    flush_threshold: usize = 64 * 1024,
};

const MAGIC = "PGCOPY\n\xFF\r\n\x00";
pub const HEADER_LEN: usize = MAGIC.len + 4 + 4; // 11 + 4 (flags) + 4 (header ext) = 19

fn writeHeader(buf: *Buffer) !void {
    try buf.ensureUnusedCapacity(HEADER_LEN);
    try buf.write(MAGIC);
    try buf.write(&.{ 0, 0, 0, 0 }); // flags
    try buf.write(&.{ 0, 0, 0, 0 }); // header extension length
}

fn writeRowInto(comptime ColumnTypes: anytype, buf: *Buffer, values: anytype) !void {
    if (values.len != ColumnTypes.len) {
        @compileError(std.fmt.comptimePrint(
            "expected {d} values, got {d}",
            .{ ColumnTypes.len, values.len },
        ));
    }
    try buf.writeIntBig(i16, @intCast(ColumnTypes.len));
    inline for (ColumnTypes, 0..) |T, i| {
        try types.writeCopyValue(T, buf, values[i]);
    }
}

fn writeFooter(buf: *Buffer) !void {
    try buf.writeIntBig(i16, -1);
}

fn fieldTypesValue(comptime Row: type) [std.meta.fields(Row).len]type {
    const fields = std.meta.fields(Row);
    var arr: [fields.len]type = undefined;
    inline for (fields, 0..) |f, i| arr[i] = f.type;
    return arr;
}

pub fn copyIntoImpl(conn: *Conn, sql: []const u8, rows: anytype, opts: CopyOpts) !i64 {
    const Slice = @TypeOf(rows);
    const Row = comptime blk: {
        const ti = @typeInfo(Slice);
        switch (ti) {
            .pointer => |p| {
                if (p.size == .slice or p.size == .many) break :blk p.child;
                if (p.size == .one) {
                    const inner = @typeInfo(p.child);
                    if (inner == .array) break :blk inner.array.child;
                }
            },
            .array => |a| break :blk a.child,
            else => {},
        }
        @compileError("copyInto expects a slice or array of structs, got " ++ @typeName(Slice));
    };
    const ColumnTypes = comptime fieldTypesValue(Row);
    const TupleT = comptime std.meta.Tuple(&ColumnTypes);

    var copy = try conn.copyInOpts(sql, ColumnTypes, opts);
    defer copy.deinit();

    const fields = comptime std.meta.fields(Row);
    for (rows) |row| {
        var tuple: TupleT = undefined;
        inline for (fields, 0..) |f, i| {
            tuple[i] = @field(row, f.name);
        }
        try copy.writeRow(tuple);
    }

    return copy.finish();
}

fn buildCopySql(allocator: Allocator, table: []const u8, comptime Row: type) ![]u8 {
    const fields = std.meta.fields(Row);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.print(allocator, "copy \"{s}\" (", .{table});
    inline for (fields, 0..) |f, i| {
        if (i > 0) try list.appendSlice(allocator, ", ");
        try list.print(allocator, "\"{s}\"", .{f.name});
    }
    try list.appendSlice(allocator, ") from stdin binary");
    return list.toOwnedSlice(allocator);
}

pub fn copyIntoTableImpl(conn: *Conn, table: []const u8, rows: anytype, opts: CopyOpts) !i64 {
    const Slice = @TypeOf(rows);
    const Row = comptime blk: {
        const ti = @typeInfo(Slice);
        switch (ti) {
            .pointer => |p| {
                if (p.size == .slice or p.size == .many) break :blk p.child;
                if (p.size == .one) {
                    const inner = @typeInfo(p.child);
                    if (inner == .array) break :blk inner.array.child;
                }
            },
            .array => |a| break :blk a.child,
            else => {},
        }
        @compileError("copyIntoTable expects a slice or array of structs, got " ++ @typeName(Slice));
    };

    const allocator = conn._allocator;
    const sql = try buildCopySql(allocator, table, Row);
    defer allocator.free(sql);

    return copyIntoImpl(conn, sql, rows, opts);
}

pub fn CopyIn(comptime ColumnTypes: anytype) type {
    return struct {
        const Self = @This();
        pub const num_columns: i16 = @intCast(ColumnTypes.len);

        conn: *Conn,
        buf: Buffer,
        opts: CopyOpts,
        finished: bool,

        pub fn init(conn: *Conn, opts: CopyOpts) !Self {
            var buf = try Buffer.init(conn._allocator, @max(opts.flush_threshold, HEADER_LEN + 64));
            errdefer buf.deinit();
            try writeHeader(&buf);
            return .{
                .conn = conn,
                .buf = buf,
                .opts = opts,
                .finished = false,
            };
        }

        pub fn writeRow(self: *Self, values: anytype) !void {
            try writeRowInto(ColumnTypes, &self.buf, values);
            if (self.buf.len() >= self.opts.flush_threshold) {
                try self.flush();
            }
        }

        pub fn flush(self: *Self) !void {
            if (self.buf.len() == 0) return;
            const cd = proto.CopyData{ .payload = self.buf.string() };
            self.conn._buf.reset();
            try cd.write(&self.conn._buf);
            try self.conn.write(self.conn._buf.string());
            self.buf.reset();
        }

        pub fn finish(self: *Self) !i64 {
            if (self.finished) return 0;
            try writeFooter(&self.buf);
            try self.flush();
            self.finished = true;

            self.conn._buf.reset();
            const done = proto.CopyDone{};
            try done.write(&self.conn._buf);
            try self.conn.write(self.conn._buf.string());

            var affected: ?i64 = null;
            while (true) {
                const msg = self.conn.read() catch |err| {
                    if (err == error.PG) {
                        self.conn.readyForQuery() catch {};
                    }
                    return err;
                };
                switch (msg.type) {
                    'C' => {
                        const cc = try proto.CommandComplete.parse(msg.data);
                        affected = cc.rowsAffected();
                    },
                    'Z' => return affected orelse 0,
                    else => return self.conn.unexpectedDBMessage(),
                }
            }
        }

        pub fn cancel(self: *Self, reason: []const u8) !void {
            if (self.finished) return;
            self.finished = true;

            self.conn._buf.reset();
            const cf = proto.CopyFail{ .reason = reason };
            try cf.write(&self.conn._buf);
            try self.conn.write(self.conn._buf.string());

            while (true) {
                const msg = self.conn.read() catch |err| {
                    if (err == error.PG) {
                        // The error message that the server emits in response to
                        // CopyFail is expected — clear it and keep draining.
                        self.conn.err = null;
                        continue;
                    }
                    return err;
                };
                if (msg.type == 'Z') return;
            }
        }

        pub fn deinit(self: *Self) void {
            if (!self.finished) {
                self.cancel("aborted by deinit") catch {
                    self.conn._state = .fail;
                };
            }
            self.buf.deinit();
        }
    };
}

const t = lib.testing;
test "copy: header bytes are exactly 19 bytes with PGCOPY magic" {
    try t.expectEqual(@as(usize, 19), HEADER_LEN);
    try t.expectString("PGCOPY\n\xFF\r\n\x00", MAGIC);
}

test "CopyIn.writeRow: header + one row of (i32, []const u8)" {
    var buf = try Buffer.init(t.allocator, 64);
    errdefer buf.deinit();

    try writeHeader(&buf);

    const Cols = .{ i32, []const u8 };
    try writeRowInto(Cols, &buf, .{ 7, "ab" });

    const out = buf.string();

    // 19 header bytes
    try std.testing.expectEqualSlices(u8, "PGCOPY\n\xFF\r\n\x00" ++ &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, out[0..19]);

    // i16 num_cols = 2
    try t.expectEqual(@as(u8, 0), out[19]);
    try t.expectEqual(@as(u8, 2), out[20]);

    // col 0: i32 length=4, value 7
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 0, 0, 0, 7 }, out[21..29]);

    // col 1: i32 length=2, "ab"
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 'a', 'b' }, out[29..35]);

    buf.deinit();
}

test "CopyIn footer is i16 -1" {
    var buf = try Buffer.init(t.allocator, 32);
    defer buf.deinit();

    try writeFooter(&buf);

    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF }, buf.string());
}

test "CopyIn: happy path inserts rows" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_basic", .{});
    _ = try conn.exec(
        "create table copy_test_basic (id int4 not null, name text not null)",
        .{},
    );

    {
        var copy = try conn.copyIn(
            "copy copy_test_basic (id, name) from stdin binary",
            .{ i32, []const u8 },
        );
        defer copy.deinit();
        try copy.writeRow(.{ @as(i32, 1), "alice" });
        try copy.writeRow(.{ @as(i32, 2), "bob" });
        try copy.writeRow(.{ @as(i32, 3), "carol" });
        const n = try copy.finish();
        try t.expectEqual(@as(i64, 3), n);
    }

    var result = try conn.queryOpts(
        "select id, name from copy_test_basic order by id",
        .{},
        .{},
    );
    defer result.deinit();

    var i: usize = 0;
    while (try result.next()) |row| : (i += 1) {
        switch (i) {
            0 => {
                try t.expectEqual(@as(i32, 1), try row.get(i32, 0));
                try t.expectString("alice", try row.get([]const u8, 1));
            },
            1 => {
                try t.expectEqual(@as(i32, 2), try row.get(i32, 0));
                try t.expectString("bob", try row.get([]const u8, 1));
            },
            2 => {
                try t.expectEqual(@as(i32, 3), try row.get(i32, 0));
                try t.expectString("carol", try row.get([]const u8, 1));
            },
            else => unreachable,
        }
    }
    try t.expectEqual(@as(usize, 3), i);

    _ = try conn.exec("drop table copy_test_basic", .{});
}

test "copyInto: struct slice helper" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_into", .{});
    _ = try conn.exec(
        "create table copy_test_into (id int4 not null, name text not null)",
        .{},
    );

    const Row = struct { id: i32, name: []const u8 };
    const rows = [_]Row{
        .{ .id = 10, .name = "x" },
        .{ .id = 20, .name = "y" },
    };

    const n = try conn.copyInto(
        "copy copy_test_into (id, name) from stdin binary",
        &rows,
    );
    try t.expectEqual(@as(i64, 2), n);

    var result = try conn.queryOpts("select count(*)::int4 from copy_test_into", .{}, .{});
    defer result.deinit();
    const row = (try result.next()).?;
    try t.expectEqual(@as(i32, 2), try row.get(i32, 0));
    try t.expectEqual(null, try result.next());

    _ = try conn.exec("drop table copy_test_into", .{});
}

test "buildCopySql: quotes table and column names" {
    const Row = struct { id: i32, name: []const u8, created_at: i64 };
    const sql = try buildCopySql(t.allocator, "users", Row);
    defer t.allocator.free(sql);

    try t.expectString(
        "copy \"users\" (\"id\", \"name\", \"created_at\") from stdin binary",
        sql,
    );
}

test "copyIntoTable: auto-generated SQL inserts rows" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_auto", .{});
    _ = try conn.exec(
        "create table copy_test_auto (id int4 not null, name text not null)",
        .{},
    );

    const Row = struct { id: i32, name: []const u8 };
    const rows = [_]Row{
        .{ .id = 100, .name = "p" },
        .{ .id = 200, .name = "q" },
    };

    const n = try conn.copyIntoTable("copy_test_auto", &rows);
    try t.expectEqual(@as(i64, 2), n);

    var result = try conn.queryOpts("select count(*)::int4 from copy_test_auto", .{}, .{});
    defer result.deinit();
    const row = (try result.next()).?;
    try t.expectEqual(@as(i32, 2), try row.get(i32, 0));
    try t.expectEqual(null, try result.next());

    _ = try conn.exec("drop table copy_test_auto", .{});
}

test "CopyIn: nullable columns" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_null", .{});
    _ = try conn.exec(
        "create table copy_test_null (id int4 not null, label text)",
        .{},
    );

    const Row = struct { id: i32, label: ?[]const u8 };
    const rows = [_]Row{
        .{ .id = 1, .label = "hi" },
        .{ .id = 2, .label = null },
        .{ .id = 3, .label = "ok" },
    };

    const n = try conn.copyIntoTable("copy_test_null", &rows);
    try t.expectEqual(@as(i64, 3), n);

    var result = try conn.queryOpts(
        "select id, label from copy_test_null order by id",
        .{},
        .{},
    );
    defer result.deinit();

    var i: usize = 0;
    while (try result.next()) |row| : (i += 1) {
        const id = try row.get(i32, 0);
        const label = try row.get(?[]const u8, 1);
        switch (i) {
            0 => {
                try t.expectEqual(@as(i32, 1), id);
                try t.expectString("hi", label.?);
            },
            1 => {
                try t.expectEqual(@as(i32, 2), id);
                try t.expectEqual(@as(?[]const u8, null), label);
            },
            2 => {
                try t.expectEqual(@as(i32, 3), id);
                try t.expectString("ok", label.?);
            },
            else => unreachable,
        }
    }
    try t.expectEqual(@as(usize, 3), i);

    _ = try conn.exec("drop table copy_test_null", .{});
}

test "CopyIn: 100k rows triggers multiple flushes" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_big", .{});
    _ = try conn.exec("create table copy_test_big (n int4 not null)", .{});

    {
        var copy = try conn.copyIn(
            "copy copy_test_big (n) from stdin binary",
            .{i32},
        );
        defer copy.deinit();
        var i: i32 = 0;
        while (i < 100_000) : (i += 1) {
            try copy.writeRow(.{i});
        }
        const n = try copy.finish();
        try t.expectEqual(@as(i64, 100_000), n);
    }

    var result = try conn.queryOpts("select count(*)::int4 from copy_test_big", .{}, .{});
    defer result.deinit();
    const row = (try result.next()).?;
    try t.expectEqual(@as(i32, 100_000), try row.get(i32, 0));
    try t.expectEqual(null, try result.next());

    _ = try conn.exec("drop table copy_test_big", .{});
}

test "CopyIn: all primitive types round-trip" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_types", .{});
    _ = try conn.exec(
        "create table copy_test_types (" ++
            " a bool not null," ++
            " b int2 not null," ++
            " c int4 not null," ++
            " d int8 not null," ++
            " e float4 not null," ++
            " f float8 not null," ++
            " g text not null" ++
            ")",
        .{},
    );

    var copy = try conn.copyIn(
        "copy copy_test_types (a, b, c, d, e, f, g) from stdin binary",
        .{ bool, i16, i32, i64, f32, f64, []const u8 },
    );
    defer copy.deinit();
    try copy.writeRow(.{ true, @as(i16, -7), @as(i32, 7), @as(i64, 7000000000), @as(f32, 1.5), @as(f64, 2.5), "ok" });
    try t.expectEqual(@as(i64, 1), try copy.finish());

    var result = try conn.queryOpts("select a, b, c, d, e, f, g from copy_test_types", .{}, .{});
    defer result.deinit();
    const row = (try result.next()).?;
    try t.expectEqual(true, try row.get(bool, 0));
    try t.expectEqual(@as(i16, -7), try row.get(i16, 1));
    try t.expectEqual(@as(i32, 7), try row.get(i32, 2));
    try t.expectEqual(@as(i64, 7000000000), try row.get(i64, 3));
    try t.expectEqual(@as(f32, 1.5), try row.get(f32, 4));
    try t.expectEqual(@as(f64, 2.5), try row.get(f64, 5));
    try t.expectString("ok", try row.get([]const u8, 6));
    _ = try result.next(); // drain

    _ = try conn.exec("drop table copy_test_types", .{});
}

test "CopyIn: zero rows returns 0 affected" {
    var conn = t.connect(.{});
    defer conn.deinit();

    _ = try conn.exec("drop table if exists copy_test_empty", .{});
    _ = try conn.exec("create table copy_test_empty (n int4 not null)", .{});

    {
        var copy = try conn.copyIn(
            "copy copy_test_empty (n) from stdin binary",
            .{i32},
        );
        defer copy.deinit();
        try t.expectEqual(@as(i64, 0), try copy.finish());
    }

    var result = try conn.queryOpts("select count(*)::int4 from copy_test_empty", .{}, .{});
    defer result.deinit();
    const row = (try result.next()).?;
    try t.expectEqual(@as(i32, 0), try row.get(i32, 0));
    _ = try result.next(); // drain

    _ = try conn.exec("drop table copy_test_empty", .{});
}
