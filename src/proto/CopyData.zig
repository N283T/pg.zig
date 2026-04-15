const std = @import("std");
const proto = @import("_proto.zig");

const CopyData = @This();

payload: []const u8,

pub fn write(self: CopyData, buf: *proto.Buffer) !void {
    // 'd' [i32 payload_len] [payload bytes]
    // payload_len includes the 4 bytes of the length field itself
    const payload_len: u32 = @intCast(4 + self.payload.len);
    const total_len = 1 + payload_len;
    try buf.ensureTotalCapacity(total_len);
    var view = buf.skip(total_len) catch unreachable;
    view.writeByte('d');
    view.writeIntBig(u32, payload_len);
    view.write(self.payload);
}

const t = proto.testing;
const Reader = proto.Reader;
test "CopyData: write" {
    var buf = try proto.Buffer.init(t.allocator, 64);
    defer buf.deinit();

    const cd = CopyData{ .payload = "hello" };
    try cd.write(&buf);

    var reader = Reader.init(buf.string());
    try t.expectEqual('d', try reader.byte());
    try t.expectEqual(9, try reader.int32());
    try t.expectString("hello", reader.rest());
}

test "CopyData: write empty payload" {
    var buf = try proto.Buffer.init(t.allocator, 64);
    defer buf.deinit();

    const cd = CopyData{ .payload = "" };
    try cd.write(&buf);

    var reader = Reader.init(buf.string());
    try t.expectEqual('d', try reader.byte());
    try t.expectEqual(4, try reader.int32());
    try t.expectString("", reader.rest());
}
