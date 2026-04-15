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

pub fn CopyIn(comptime ColumnTypes: anytype) type {
    return struct {
        const Self = @This();
        pub const num_columns: i16 = @intCast(ColumnTypes.len);

        conn: *Conn,
        buf: Buffer,
        opts: CopyOpts,
        finished: bool,

        pub fn deinit(self: *Self) void {
            self.buf.deinit();
        }

        // Other methods (init, writeRow, flush, finish, cancel) land in later tasks.
    };
}

const t = lib.testing;
test "copy: header bytes are exactly 19 bytes with PGCOPY magic" {
    try t.expectEqual(@as(usize, 19), HEADER_LEN);
    try t.expectString("PGCOPY\n\xFF\r\n\x00", MAGIC);
}
