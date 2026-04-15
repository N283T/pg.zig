const std = @import("std");
const proto = @import("_proto.zig");

const CopyDone = @This();

pub fn write(_: CopyDone, buf: *proto.Buffer) !void {
    try buf.ensureTotalCapacity(5);
    var view = buf.skip(5) catch unreachable;
    view.write(&.{ 'c', 0, 0, 0, 4 });
}

const t = proto.testing;
const Reader = proto.Reader;
test "CopyDone: write" {
    var buf = try proto.Buffer.init(t.allocator, 16);
    defer buf.deinit();

    const c = CopyDone{};
    try c.write(&buf);

    var reader = Reader.init(buf.string());
    try t.expectEqual('c', try reader.byte());
    try t.expectEqual(4, try reader.int32()); // payload length
    try t.expectString("", reader.rest());
}
