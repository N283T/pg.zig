const std = @import("std");
const proto = @import("_proto.zig");

const CopyFail = @This();

reason: []const u8,

pub fn write(self: CopyFail, buf: *proto.Buffer) !void {
    // 'f' [i32 payload_len] [reason bytes] [0]
    const payload_len: u32 = @intCast(4 + self.reason.len + 1);
    const total_len = 1 + payload_len;
    try buf.ensureTotalCapacity(total_len);
    var view = buf.skip(total_len) catch unreachable;
    view.writeByte('f');
    view.writeIntBig(u32, payload_len);
    view.write(self.reason);
    view.writeByte(0);
}

const t = proto.testing;
const Reader = proto.Reader;
test "CopyFail: write" {
    var buf = try proto.Buffer.init(t.allocator, 64);
    defer buf.deinit();

    const cf = CopyFail{ .reason = "abort" };
    try cf.write(&buf);

    var reader = Reader.init(buf.string());
    try t.expectEqual('f', try reader.byte());
    // payload = 4 (len) + 5 ("abort") + 1 (null) = 10
    try t.expectEqual(10, try reader.int32());
    try t.expectString("abort", try reader.string());
}

test "CopyFail: write empty reason" {
    var buf = try proto.Buffer.init(t.allocator, 64);
    defer buf.deinit();

    const cf = CopyFail{ .reason = "" };
    try cf.write(&buf);

    var reader = Reader.init(buf.string());
    try t.expectEqual('f', try reader.byte());
    try t.expectEqual(5, try reader.int32());
    try t.expectString("", try reader.string());
}
