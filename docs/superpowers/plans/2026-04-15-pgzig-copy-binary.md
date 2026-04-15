# pg.zig: COPY FROM STDIN (binary) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `COPY FROM STDIN BINARY` support to pg.zig with a streaming `CopyIn` primitive plus two convenience helpers (`copyInto`, `copyIntoTable`) for high-throughput bulk inserts.

**Architecture:** Three new wire-message serialisers (`CopyData`, `CopyDone`, `CopyFail`) follow the existing one-file-per-message pattern. A new `src/copy.zig` owns the binary payload (header / per-row encoding via `inline for` over a comptime tuple of column types / footer) and the COPY-mode protocol turn-taking. The existing per-type binary encoders in `types.zig` are exposed via a single dispatcher (`writeCopyValue`) that the COPY path reuses without duplicating per-type logic. A new `Conn.State.copy_in` blocks concurrent queries while a COPY is in flight.

**Tech Stack:** Zig 0.15, pg.zig conventions (Buffer, Reader, proto/, types/, conn.zig), Docker Compose PostgreSQL for integration tests.

**Spec:** `docs/superpowers/specs/2026-04-15-pgzig-copy-binary-design.md`

**Branch:** `feature/copy-binary-design` (already created and checked out, fork remote = `origin → N283T/pg.zig`, push to `upstream` is disabled).

---

## File Map

| File | Purpose | Action |
|---|---|---|
| `src/proto/CopyData.zig` | `'d'` message serialiser | Create |
| `src/proto/CopyDone.zig` | `'c'` message serialiser | Create |
| `src/proto/CopyFail.zig` | `'f'` message serialiser | Create |
| `src/copy.zig` | `CopyIn(ColumnTypes)` generic + 3 `Conn` method bodies + integration tests | Create |
| `src/proto.zig` | Re-export new proto modules | Modify |
| `src/types.zig` | Expose `writeCopyValue(comptime T, buf, value)` dispatcher | Modify |
| `src/conn.zig` | Add `.copy_in` state + 3 public methods (and `*Opts` variants) | Modify |
| `src/lib.zig` | Re-export `CopyIn`, `CopyOpts` | Modify |
| `src/pg.zig` | Re-export `CopyIn`, `CopyOpts` | Modify |
| `readme.md` | Add "Bulk insert (COPY)" section | Modify |

---

## Task 1: Verify baseline build and tests pass

**Files:** none

- [ ] **Step 1: Confirm the test PostgreSQL is up**

```bash
cd /Users/nagaet/ghq/github.com/karlseguin/pg.zig/tests && docker compose up -d && cd ..
```

Expected: containers `pg.zig-pg-1` (and similar) running. Run `docker ps | grep pg.zig` to confirm.

- [ ] **Step 2: Run existing test suite to set the baseline**

```bash
cd /Users/nagaet/ghq/github.com/karlseguin/pg.zig && make t
```

Expected: all tests pass (or at minimum: the same set that pass on `master` pass here). Note any pre-existing failures so they are not blamed on later work.

- [ ] **Step 3: No commit (this task only verifies baseline).**

---

## Task 2: `proto/CopyDone.zig` — fixed-size `'c'` message

**Files:**
- Create: `src/proto/CopyDone.zig`

- [ ] **Step 1: Write the failing test first**

Create `src/proto/CopyDone.zig` with only the test (no implementation) so the build fails.

```zig
const std = @import("std");
const proto = @import("_proto.zig");

const CopyDone = @This();

pub fn write(_: CopyDone, buf: *proto.Buffer) !void {
    _ = buf;
    @compileError("not implemented");
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
```

- [ ] **Step 2: Try to build, observe the compile error**

```bash
make t F=CopyDone
```

Expected: build fails on `@compileError("not implemented")`.

- [ ] **Step 3: Implement `write`**

Replace the `write` body:

```zig
pub fn write(_: CopyDone, buf: *proto.Buffer) !void {
    try buf.ensureTotalCapacity(5);
    var view = buf.skip(5) catch unreachable;
    view.write(&.{ 'c', 0, 0, 0, 4 });
}
```

- [ ] **Step 4: Run the test**

```bash
make t F=CopyDone
```

Expected: 1 test passing. (The new file is not referenced from `proto.zig` yet, so it will only run if `make t` already does a full `refAllDecls` over the file; if it does not, also temporarily add the export per Task 5 to make the test discoverable. Verify it passes either way.)

- [ ] **Step 5: Commit**

```bash
git add src/proto/CopyDone.zig
git commit -m "feat: add CopyDone proto message"
```

---

## Task 3: `proto/CopyData.zig` — variable-length `'d'` wrapper

**Files:**
- Create: `src/proto/CopyData.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const proto = @import("_proto.zig");

const CopyData = @This();

payload: []const u8,

pub fn write(self: CopyData, buf: *proto.Buffer) !void {
    _ = self;
    _ = buf;
    @compileError("not implemented");
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
    // payload length = 4 (length field itself) + 5 ("hello")
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
```

- [ ] **Step 2: Build, observe failure**

```bash
make t F=CopyData
```

Expected: build fails.

- [ ] **Step 3: Implement `write`**

```zig
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
```

- [ ] **Step 4: Run tests**

```bash
make t F=CopyData
```

Expected: 2 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/proto/CopyData.zig
git commit -m "feat: add CopyData proto message"
```

---

## Task 4: `proto/CopyFail.zig` — `'f'` with reason string

**Files:**
- Create: `src/proto/CopyFail.zig`

- [ ] **Step 1: Write the failing test**

```zig
const std = @import("std");
const proto = @import("_proto.zig");

const CopyFail = @This();

reason: []const u8,

pub fn write(self: CopyFail, buf: *proto.Buffer) !void {
    _ = self;
    _ = buf;
    @compileError("not implemented");
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
    // payload = 4 (len field) + 5 ("abort") + 1 (null term) = 10
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
```

- [ ] **Step 2: Observe failure**

```bash
make t F=CopyFail
```

- [ ] **Step 3: Implement**

```zig
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
```

- [ ] **Step 4: Run tests**

```bash
make t F=CopyFail
```

Expected: 2 tests passing.

- [ ] **Step 5: Commit**

```bash
git add src/proto/CopyFail.zig
git commit -m "feat: add CopyFail proto message"
```

---

## Task 5: Re-export new proto modules

**Files:**
- Modify: `src/proto.zig`

- [ ] **Step 1: Add three exports**

Append after the existing `Sync` line in `src/proto.zig`:

```zig
pub const CopyData = @import("proto/CopyData.zig");
pub const CopyDone = @import("proto/CopyDone.zig");
pub const CopyFail = @import("proto/CopyFail.zig");
```

- [ ] **Step 2: Verify everything still builds and the new tests are picked up**

```bash
make t
```

Expected: full suite passes; the `Copy*` tests are now part of `refAllDecls`.

- [ ] **Step 3: Commit**

```bash
git add src/proto.zig
git commit -m "feat: export Copy{Data,Done,Fail} from proto"
```

---

## Task 6: `types.writeCopyValue` — central per-type binary encoder

**Files:**
- Modify: `src/types.zig`

This task adds **one** public function whose only job is `[i32 length][value bytes]` — i.e. the COPY row payload for a single column. It does **not** write the format-code byte that the Bind path needs. Internally it delegates to the existing per-type encoders by composing the same byte sequences.

- [ ] **Step 1: Add the failing test (unit-style, no PG required)**

Append to `src/types.zig`:

```zig
test "writeCopyValue: i32" {
    var buf = try buffer.Buffer.init(std.testing.allocator, 64);
    defer buf.deinit();

    try writeCopyValue(i32, &buf, 42);

    const out = buf.string();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 0, 0, 0, 42 }, out);
}

test "writeCopyValue: optional i32 null" {
    var buf = try buffer.Buffer.init(std.testing.allocator, 64);
    defer buf.deinit();

    try writeCopyValue(?i32, &buf, null);

    const out = buf.string();
    // -1 as big-endian i32 = 0xFFFFFFFF, no value bytes
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF }, out);
}

test "writeCopyValue: optional i32 some" {
    var buf = try buffer.Buffer.init(std.testing.allocator, 64);
    defer buf.deinit();

    try writeCopyValue(?i32, &buf, 7);

    const out = buf.string();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 0, 0, 0, 7 }, out);
}

test "writeCopyValue: []const u8" {
    var buf = try buffer.Buffer.init(std.testing.allocator, 64);
    defer buf.deinit();

    try writeCopyValue([]const u8, &buf, "hi");

    const out = buf.string();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 'h', 'i' }, out);
}

test "writeCopyValue: bool" {
    var buf = try buffer.Buffer.init(std.testing.allocator, 64);
    defer buf.deinit();

    try writeCopyValue(bool, &buf, true);

    const out = buf.string();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 1 }, out);
}

test "writeCopyValue: i64" {
    var buf = try buffer.Buffer.init(std.testing.allocator, 64);
    defer buf.deinit();

    try writeCopyValue(i64, &buf, 0x0102030405060708);

    const out = buf.string();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8 }, out);
}
```

- [ ] **Step 2: Build, observe failure**

```bash
make t F=writeCopyValue
```

Expected: build fails (`writeCopyValue` undefined).

- [ ] **Step 3: Implement the dispatcher**

Append before the test block in `src/types.zig`:

```zig
const NULL_LEN_BE = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF };

/// Writes one column value in PostgreSQL COPY binary row format:
///     [i32 length] [value bytes]
/// or  [-1] (for null optionals)
///
/// Reuses the same wire layout as the Bind path; the only difference is that
/// COPY does not need a per-column format-code byte.
pub fn writeCopyValue(comptime T: type, buf: *buffer.Buffer, value: T) !void {
    const ti = @typeInfo(T);
    if (ti == .optional) {
        if (value) |v| {
            return writeCopyValue(ti.optional.child, buf, v);
        }
        try buf.write(&NULL_LEN_BE);
        return;
    }

    // Primitives
    switch (T) {
        bool => {
            try buf.write(&.{ 0, 0, 0, 1 });
            try buf.writeByte(if (value) 1 else 0);
            return;
        },
        i16 => {
            try buf.write(&.{ 0, 0, 0, 2 });
            try buf.writeIntBig(i16, value);
            return;
        },
        u16 => {
            if (value > 32767) return error.UnsignedIntWouldBeTruncated;
            try buf.write(&.{ 0, 0, 0, 2 });
            try buf.writeIntBig(i16, @intCast(value));
            return;
        },
        i32 => {
            try buf.write(&.{ 0, 0, 0, 4 });
            try buf.writeIntBig(i32, value);
            return;
        },
        u32 => {
            if (value > 2147483647) return error.UnsignedIntWouldBeTruncated;
            try buf.write(&.{ 0, 0, 0, 4 });
            try buf.writeIntBig(i32, @intCast(value));
            return;
        },
        i64 => {
            try buf.write(&.{ 0, 0, 0, 8 });
            try buf.writeIntBig(i64, value);
            return;
        },
        u64 => {
            if (value > 9223372036854775807) return error.UnsignedIntWouldBeTruncated;
            try buf.write(&.{ 0, 0, 0, 8 });
            try buf.writeIntBig(i64, @intCast(value));
            return;
        },
        f32 => {
            try buf.write(&.{ 0, 0, 0, 4 });
            const tmp: *const i32 = @ptrCast(&value);
            try buf.writeIntBig(i32, tmp.*);
            return;
        },
        f64 => {
            try buf.write(&.{ 0, 0, 0, 8 });
            const tmp: *const i64 = @ptrCast(&value);
            try buf.writeIntBig(i64, tmp.*);
            return;
        },
        []const u8, []u8 => {
            var view = try buf.skip(4 + value.len);
            view.writeIntBig(i32, @intCast(value.len));
            view.write(value);
            return;
        },
        else => {},
    }

    // Fixed-size byte arrays (e.g. uuid as [16]u8)
    if (ti == .array and ti.array.child == u8) {
        var view = try buf.skip(4 + value.len);
        view.writeIntBig(i32, @intCast(value.len));
        view.write(&value);
        return;
    }

    @compileError("writeCopyValue: unsupported type " ++ @typeName(T));
}
```

- [ ] **Step 4: Run the new tests**

```bash
make t F=writeCopyValue
```

Expected: 6 tests pass.

- [ ] **Step 5: Run the full suite to make sure nothing regressed**

```bash
make t
```

Expected: full suite green.

- [ ] **Step 6: Commit**

```bash
git add src/types.zig
git commit -m "feat: add types.writeCopyValue dispatcher for COPY binary"
```

> NOTE: Array, `Numeric`, `Cidr`, and user `pgEncode` types are intentionally **not** wired up here. They are noted as future work in the spec; if needed during implementation, extend `writeCopyValue` with additional branches, with one focused commit per type added.

---

## Task 7: `src/copy.zig` skeleton — `CopyIn(ColumnTypes)` struct + header

**Files:**
- Create: `src/copy.zig`

This task only sets up the type, the binary header bytes, and `deinit`. `writeRow`, `flush`, `finish`, and `cancel` come in subsequent tasks.

- [ ] **Step 1: Write a unit test that asserts the header bytes**

Create `src/copy.zig`:

```zig
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

        // Other methods land in later tasks.
    };
}

const t = lib.testing;
test "copy: header bytes are exactly 19 bytes with PGCOPY magic" {
    // Header layout assertion (independent of CopyIn struct)
    try t.expectEqual(@as(usize, 19), HEADER_LEN);
    try t.expectString("PGCOPY\n\xFF\r\n\x00", MAGIC);
}
```

- [ ] **Step 2: Run the test (must pass since logic is just constants)**

We also need to make this file discoverable. Edit `src/lib.zig` and add after the `pub const Stream` line:

```zig
pub const copy = @import("copy.zig");
pub const CopyIn = copy.CopyIn;
pub const CopyOpts = copy.CopyOpts;
```

Then:

```bash
make t F=copy:
```

Expected: 1 test passing.

- [ ] **Step 3: Commit**

```bash
git add src/copy.zig src/lib.zig
git commit -m "feat: add copy.zig skeleton with PGCOPY binary header"
```

---

## Task 8: `CopyIn.init` and `CopyIn.writeRow` (with auto-flush)

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: Write a unit test**

In `src/copy.zig`, append a new test that drives `init` and `writeRow` against a stub buffer (no real connection — `init` for the unit test path takes a buffer-only constructor we'll add).

For unit testing without a real `Conn`, expose an internal helper `initWithBuffer` that the test uses; the production `init` path (called from `Conn.copyIn`) will be added in Task 11.

Append:

```zig
test "CopyIn.writeRow: header + one row of (i32, []const u8)" {
    var buf = try Buffer.init(t.allocator, 64);
    errdefer buf.deinit();

    // Manually pre-seed with header; init does this in the real path.
    try writeHeader(&buf);

    const Cols = .{ i32, []const u8 };
    try writeRowInto(Cols, &buf, .{ 7, "ab" });

    const out = buf.string();

    // 19 header bytes
    try t.expectEqualSlices(u8, "PGCOPY\n\xFF\r\n\x00" ++ &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, out[0..19]);

    // i16 num_cols = 2
    try t.expectEqual(@as(u8, 0), out[19]);
    try t.expectEqual(@as(u8, 2), out[20]);

    // col 0: i32 length=4, value 7
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 0, 0, 0, 7 }, out[21..29]);

    // col 1: i32 length=2, "ab"
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 2, 'a', 'b' }, out[29..35]);

    buf.deinit();
}
```

- [ ] **Step 2: Build, observe failure**

```bash
make t F=writeRow
```

Expected: build fails (`writeHeader`/`writeRowInto` undefined).

- [ ] **Step 3: Implement two private helpers + wire them into `CopyIn`**

In `src/copy.zig`, before the `CopyIn` definition add:

```zig
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
```

Then add the production `writeRow` and a new `init` (real one) inside `CopyIn`:

```zig
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
    // Encode the wire-level message into a small staging buffer to avoid
    // allocating in the hot path; reuse the conn's existing write buffer.
    self.conn._buf.reset();
    try cd.write(&self.conn._buf);
    try self.conn.write(self.conn._buf.string());
    self.buf.reset();
}
```

> NOTE: `_buf` and `_allocator` are accessed on `Conn`. Both are already field-level (`pub` is implicit on struct fields in Zig as long as the struct itself is `pub`). If you find them not accessible from `copy.zig`, add minimal `pub fn rawAllocator(self: *Conn) Allocator` / `pub fn rawWriteBuffer(self: *Conn) *Buffer` accessors in `src/conn.zig`. Prefer direct field access.

- [ ] **Step 4: Run unit tests**

```bash
make t F=writeRow
```

Expected: 1 test passing (uses `writeHeader` and `writeRowInto` directly, not the full `CopyIn` path).

- [ ] **Step 5: Run the full suite to be safe**

```bash
make t
```

Expected: full suite green.

- [ ] **Step 6: Commit**

```bash
git add src/copy.zig
git commit -m "feat: implement CopyIn header + writeRow with auto-flush"
```

---

## Task 9: `CopyIn.finish` and `CopyIn.cancel`

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: Add a unit test for the footer bytes**

Append:

```zig
test "CopyIn footer is i16 -1" {
    var buf = try Buffer.init(t.allocator, 32);
    defer buf.deinit();

    try writeFooter(&buf);

    try t.expectEqualSlices(u8, &.{ 0xFF, 0xFF }, buf.string());
}
```

- [ ] **Step 2: Build, observe failure**

```bash
make t F=footer
```

- [ ] **Step 3: Implement footer + finish + cancel**

Add to `src/copy.zig`:

```zig
fn writeFooter(buf: *Buffer) !void {
    try buf.writeIntBig(i16, -1);
}
```

And inside `CopyIn`:

```zig
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

    // Drain until ReadyForQuery; the server is required to send an Error
    // followed by Z. We swallow the Error because cancellation is the
    // user's intent.
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
```

- [ ] **Step 4: Update `deinit` for auto-cancel**

Replace the `deinit` body added in Task 7 with:

```zig
pub fn deinit(self: *Self) void {
    if (!self.finished) {
        self.cancel("aborted by deinit") catch {
            self.conn._state = .fail;
        };
    }
    self.buf.deinit();
}
```

- [ ] **Step 5: Run unit tests**

```bash
make t F=footer
```

Expected: footer test passes. Full integration of `finish`/`cancel` is exercised in Task 11.

- [ ] **Step 6: Run full suite**

```bash
make t
```

Expected: green.

- [ ] **Step 7: Commit**

```bash
git add src/copy.zig
git commit -m "feat: implement CopyIn finish, cancel, and auto-cancel deinit"
```

---

## Task 10: Wire `Conn.copyIn` (state transition + start handshake)

**Files:**
- Modify: `src/conn.zig`
- Modify: `src/copy.zig`

- [ ] **Step 1: Add `.copy_in` to `Conn.State`**

In `src/conn.zig`, modify the `State` enum (currently around line 65) to add `copy_in`:

```zig
const State = enum {
    idle,
    fail,
    query,
    transaction,
    copy_in,
};
```

- [ ] **Step 2: Make sure `canQuery` does not allow new queries while in `.copy_in`**

The existing `canQuery` returns true only for `.idle` and `.transaction`, so no change needed. Confirm by reading the current implementation in `src/conn.zig`.

- [ ] **Step 3: Update the post-`Z` state mapping if needed**

The existing handler for `'Z'` (around line 478 in `src/conn.zig`) maps the byte to `.idle` / `.transaction` / `.fail`. No change needed — after a COPY completes, the server sends `Z 'I'` or `Z 'T'` and the existing branch handles it. Re-read those lines and confirm.

- [ ] **Step 4: Add `Conn.copyIn` and `Conn.copyInOpts`**

Append inside the `Conn` struct in `src/conn.zig`:

```zig
pub fn copyIn(self: *Conn, sql: []const u8, comptime ColumnTypes: anytype) !lib.copy.CopyIn(ColumnTypes) {
    return self.copyInOpts(sql, ColumnTypes, .{});
}

pub fn copyInOpts(
    self: *Conn,
    sql: []const u8,
    comptime ColumnTypes: anytype,
    opts: lib.copy.CopyOpts,
) !lib.copy.CopyIn(ColumnTypes) {
    if (self.canQuery() == false) return error.ConnectionBusy;

    var buf = &self._buf;
    buf.reset();
    try self._reader.startFlow(opts.flush_threshold, null);
    errdefer self._reader.endFlow() catch {
        self._state = .fail;
    };

    const q = proto.Query{ .sql = sql };
    try q.write(buf);
    self._state = .copy_in;
    try self.write(buf.string());

    // Expect CopyInResponse 'G' or Error 'E'
    while (true) {
        const msg = self.read() catch |err| {
            if (err == error.PG) self.readyForQuery() catch {};
            return err;
        };
        switch (msg.type) {
            'G' => {
                // First byte is overall format: 0=text, 1=binary. We sent
                // BINARY so we expect 1.
                if (msg.data.len < 1 or msg.data[0] != 1) {
                    self._state = .fail;
                    return error.UnexpectedDBMessage;
                }
                return lib.copy.CopyIn(ColumnTypes).init(self, opts);
            },
            else => return self.unexpectedDBMessage(),
        }
    }
}
```

> NOTE: The `_reader.startFlow` / `endFlow` arguments above mirror what `execOpts` does. If the existing signature differs, match it exactly — do not invent new parameters. Re-read `src/reader.zig` to confirm.

- [ ] **Step 5: Re-export `CopyIn` and `CopyOpts` from `pg.zig`**

In `src/pg.zig`, add after the existing `pub const Binary = lib.Binary;` line:

```zig
pub const CopyIn = lib.CopyIn;
pub const CopyOpts = lib.CopyOpts;
```

- [ ] **Step 6: Build to confirm everything compiles**

```bash
make t
```

Expected: full suite green.

- [ ] **Step 7: Commit**

```bash
git add src/conn.zig src/pg.zig
git commit -m "feat: add Conn.copyIn / copyInOpts and copy_in state"
```

---

## Task 11: Integration test — happy path with `copyIn`

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: Write the failing integration test**

Append to `src/copy.zig`:

```zig
test "CopyIn: happy path inserts rows" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

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

    var rows: [3]struct { id: i32, name: []const u8 } = undefined;
    var i: usize = 0;
    while (try result.next()) |row| : (i += 1) {
        rows[i] = .{ .id = row.get(i32, 0), .name = row.get([]const u8, 1) };
    }
    try t.expectEqual(@as(usize, 3), i);
    try t.expectEqual(@as(i32, 1), rows[0].id);
    try t.expectString("alice", rows[0].name);
    try t.expectEqual(@as(i32, 3), rows[2].id);
    try t.expectString("carol", rows[2].name);
}
```

> NOTE: `t.authOpts(.{})` mirrors how other tests in `src/conn.zig` and `src/result.zig` authenticate. Re-read those files for the exact helper name (it may be `t.testAuth(...)` or similar) and copy that call verbatim.

- [ ] **Step 2: Run it (expect it to pass after the previous tasks)**

```bash
make t F=happy
```

Expected: 1 test passing. If it fails:
- Check that the test PG container is running (`docker ps`).
- Check that the `copy_test_basic` table is being created in a database the test user has permission for.
- Re-read the failure output and trace through `Conn.copyIn` → `CopyIn.writeRow` → `CopyIn.finish` to find the divergence from what the server expects.

- [ ] **Step 3: Run the full suite**

```bash
make t
```

- [ ] **Step 4: Commit**

```bash
git add src/copy.zig
git commit -m "test: add CopyIn happy-path integration test"
```

---

## Task 12: `Conn.copyInto` helper (struct slice → CopyIn)

**Files:**
- Modify: `src/conn.zig`
- Modify: `src/copy.zig`

- [ ] **Step 1: Add the helper in `src/copy.zig`**

Append:

```zig
fn fieldTypesTuple(comptime Row: type) type {
    const fields = std.meta.fields(Row);
    var arr: [fields.len]type = undefined;
    inline for (fields, 0..) |f, i| arr[i] = f.type;
    const result = arr;
    return @TypeOf(result);
}

fn fieldTypesValue(comptime Row: type) fieldTypesTuple(Row) {
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

    var copy = try conn.copyInOpts(sql, ColumnTypes, opts);
    defer copy.deinit();

    const fields = comptime std.meta.fields(Row);
    for (rows) |row| {
        var tuple: ColumnTypes = undefined;
        inline for (fields, 0..) |f, i| {
            tuple[i] = @field(row, f.name);
        }
        try copy.writeRow(tuple);
    }

    return copy.finish();
}
```

- [ ] **Step 2: Add the public methods on `Conn`**

In `src/conn.zig`:

```zig
pub fn copyInto(self: *Conn, sql: []const u8, rows: anytype) !i64 {
    return lib.copy.copyIntoImpl(self, sql, rows, .{});
}

pub fn copyIntoOpts(self: *Conn, sql: []const u8, rows: anytype, opts: lib.copy.CopyOpts) !i64 {
    return lib.copy.copyIntoImpl(self, sql, rows, opts);
}
```

- [ ] **Step 3: Add an integration test**

In `src/copy.zig`:

```zig
test "copyInto: struct slice helper" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

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

    const got = try conn.row("select count(*)::int4 from copy_test_into", .{});
    defer if (got) |*r| r.deinit() catch {};
    try t.expectEqual(@as(i32, 2), got.?.get(i32, 0));
}
```

> NOTE: `conn.row` API may look different — re-read its signature in `src/conn.zig` and adapt the test to whichever style is canonical (e.g. `try t.expectEqual(2, (try conn.exec(\"...\", .{})) orelse 0)`).

- [ ] **Step 4: Run**

```bash
make t F=copyInto
```

Expected: pass.

- [ ] **Step 5: Full suite**

```bash
make t
```

- [ ] **Step 6: Commit**

```bash
git add src/copy.zig src/conn.zig
git commit -m "feat: add Conn.copyInto helper for struct slices"
```

---

## Task 13: `Conn.copyIntoTable` helper (auto-generates SQL)

**Files:**
- Modify: `src/copy.zig`
- Modify: `src/conn.zig`

- [ ] **Step 1: Implement SQL generation + impl in `src/copy.zig`**

```zig
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

fn buildCopySql(allocator: Allocator, table: []const u8, comptime Row: type) ![]u8 {
    const fields = std.meta.fields(Row);
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();
    const w = list.writer();

    try w.print("copy \"{s}\" (", .{table});
    inline for (fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{f.name});
    }
    try w.writeAll(") from stdin binary");
    return list.toOwnedSlice();
}
```

- [ ] **Step 2: Add the public methods on `Conn`**

```zig
pub fn copyIntoTable(self: *Conn, table: []const u8, rows: anytype) !i64 {
    return lib.copy.copyIntoTableImpl(self, table, rows, .{});
}

pub fn copyIntoTableOpts(self: *Conn, table: []const u8, rows: anytype, opts: lib.copy.CopyOpts) !i64 {
    return lib.copy.copyIntoTableImpl(self, table, rows, opts);
}
```

- [ ] **Step 3: Unit test for SQL generation**

```zig
test "buildCopySql: quotes table and column names" {
    const Row = struct { id: i32, name: []const u8, created_at: i64 };
    const sql = try buildCopySql(t.allocator, "users", Row);
    defer t.allocator.free(sql);

    try t.expectString(
        "copy \"users\" (\"id\", \"name\", \"created_at\") from stdin binary",
        sql,
    );
}
```

- [ ] **Step 4: Integration test**

```zig
test "copyIntoTable: auto-generated SQL inserts rows" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

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
}
```

- [ ] **Step 5: Run**

```bash
make t F=copyIntoTable
```

- [ ] **Step 6: Commit**

```bash
git add src/copy.zig src/conn.zig
git commit -m "feat: add Conn.copyIntoTable helper that generates SQL"
```

---

## Task 14: Integration tests — nullable + large volume

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: Nullable test**

```zig
test "CopyIn: nullable columns" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

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
    try t.expectEqual(true, (try result.next()) != null); // 1
    const r2 = try result.next();
    try t.expectEqual(true, r2 != null);
    try t.expectEqual(true, r2.?.isNull(1));
    try t.expectEqual(true, (try result.next()) != null); // 3
    try t.expectEqual(true, (try result.next()) == null);
}
```

> NOTE: `row.isNull(idx)` may be named differently (`row.isNullAt`?). Re-read `src/result.zig` and use the actual API.

- [ ] **Step 2: Large-volume test (forces multiple flushes)**

```zig
test "CopyIn: 100k rows triggers multiple flushes" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

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

    const got = try conn.row("select count(*)::int4 from copy_test_big", .{});
    defer if (got) |*r| r.deinit() catch {};
    try t.expectEqual(@as(i32, 100_000), got.?.get(i32, 0));
}
```

- [ ] **Step 3: Run**

```bash
make t F=copy_test_null
make t F=copy_test_big
```

Expected: both pass.

- [ ] **Step 4: Commit**

```bash
git add src/copy.zig
git commit -m "test: add CopyIn nullable + large-volume integration tests"
```

---

## Task 15: Integration tests — all supported types + empty

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: All-types test**

```zig
test "CopyIn: all primitive types round-trip" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

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
    try t.expectEqual(true, row.get(bool, 0));
    try t.expectEqual(@as(i16, -7), row.get(i16, 1));
    try t.expectEqual(@as(i32, 7), row.get(i32, 2));
    try t.expectEqual(@as(i64, 7000000000), row.get(i64, 3));
    try t.expectEqual(@as(f32, 1.5), row.get(f32, 4));
    try t.expectEqual(@as(f64, 2.5), row.get(f64, 5));
    try t.expectString("ok", row.get([]const u8, 6));
}
```

- [ ] **Step 2: Empty (zero rows) test**

```zig
test "CopyIn: zero rows returns 0 affected" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

    _ = try conn.exec("drop table if exists copy_test_empty", .{});
    _ = try conn.exec("create table copy_test_empty (n int4 not null)", .{});

    var copy = try conn.copyIn(
        "copy copy_test_empty (n) from stdin binary",
        .{i32},
    );
    defer copy.deinit();
    try t.expectEqual(@as(i64, 0), try copy.finish());

    const got = try conn.row("select count(*)::int4 from copy_test_empty", .{});
    defer if (got) |*r| r.deinit() catch {};
    try t.expectEqual(@as(i32, 0), got.?.get(i32, 0));
}
```

- [ ] **Step 3: Run + commit**

```bash
make t F=copy_test_types
make t F=copy_test_empty
git add src/copy.zig
git commit -m "test: add CopyIn all-types and empty integration tests"
```

---

## Task 16: Integration tests — error paths

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: Error at start (table does not exist)**

```zig
test "CopyIn: error at start when table missing leaves connection usable" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

    _ = try conn.exec("drop table if exists copy_test_missing", .{});

    const r = conn.copyIn(
        "copy copy_test_missing (n) from stdin binary",
        .{i32},
    );
    try t.expectError(error.PG, r);
    try t.expect(conn.err != null);

    // Connection should be usable for a follow-up query.
    _ = try conn.exec("select 1", .{});
}
```

- [ ] **Step 2: Error at finish (constraint violation)**

```zig
test "CopyIn: NOT NULL violation surfaces at finish" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

    _ = try conn.exec("drop table if exists copy_test_null_violation", .{});
    _ = try conn.exec(
        "create table copy_test_null_violation (id int4 not null, name text not null)",
        .{},
    );

    var copy = try conn.copyIn(
        "copy copy_test_null_violation (id, name) from stdin binary",
        .{ i32, ?[]const u8 },
    );
    defer copy.deinit();
    try copy.writeRow(.{ @as(i32, 1), null });
    try t.expectError(error.PG, copy.finish());

    _ = try conn.exec("select 1", .{});
}
```

- [ ] **Step 3: Cancel mid-stream**

```zig
test "CopyIn: cancel rolls back the in-flight COPY" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

    _ = try conn.exec("drop table if exists copy_test_cancel", .{});
    _ = try conn.exec("create table copy_test_cancel (id int4 not null)", .{});

    {
        var copy = try conn.copyIn(
            "copy copy_test_cancel (id) from stdin binary",
            .{i32},
        );
        defer copy.deinit();
        try copy.writeRow(.{@as(i32, 1)});
        try copy.writeRow(.{@as(i32, 2)});
        try copy.cancel("test cancel");
    }

    _ = try conn.exec("select 1", .{});
    const got = try conn.row("select count(*)::int4 from copy_test_cancel", .{});
    defer if (got) |*r| r.deinit() catch {};
    try t.expectEqual(@as(i32, 0), got.?.get(i32, 0));
}
```

- [ ] **Step 4: Auto-cancel on `deinit`**

```zig
test "CopyIn: deinit without finish auto-cancels and connection is reusable" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

    _ = try conn.exec("drop table if exists copy_test_autocancel", .{});
    _ = try conn.exec("create table copy_test_autocancel (id int4 not null)", .{});

    {
        var copy = try conn.copyIn(
            "copy copy_test_autocancel (id) from stdin binary",
            .{i32},
        );
        try copy.writeRow(.{@as(i32, 99)});
        copy.deinit();
    }

    _ = try conn.exec("select 1", .{});
    const got = try conn.row("select count(*)::int4 from copy_test_autocancel", .{});
    defer if (got) |*r| r.deinit() catch {};
    try t.expectEqual(@as(i32, 0), got.?.get(i32, 0));
}
```

- [ ] **Step 5: Run + commit**

```bash
make t F=copy_test_missing
make t F=copy_test_null_violation
make t F=copy_test_cancel
make t F=copy_test_autocancel
git add src/copy.zig
git commit -m "test: add CopyIn error / cancel / auto-cancel integration tests"
```

---

## Task 17: Integration test — COPY inside a transaction

**Files:**
- Modify: `src/copy.zig`

- [ ] **Step 1: Test**

```zig
test "CopyIn: inside transaction, ROLLBACK discards rows" {
    var conn = try Conn.open(t.allocator, .{});
    defer conn.deinit();
    try conn.auth(t.authOpts(.{}));

    _ = try conn.exec("drop table if exists copy_test_tx", .{});
    _ = try conn.exec("create table copy_test_tx (id int4 not null)", .{});

    try conn.begin();

    const Row = struct { id: i32 };
    const rows = [_]Row{ .{ .id = 1 }, .{ .id = 2 } };
    _ = try conn.copyIntoTable("copy_test_tx", &rows);

    try conn.rollback();

    const got = try conn.row("select count(*)::int4 from copy_test_tx", .{});
    defer if (got) |*r| r.deinit() catch {};
    try t.expectEqual(@as(i32, 0), got.?.get(i32, 0));
}
```

- [ ] **Step 2: Run + commit**

```bash
make t F=copy_test_tx
git add src/copy.zig
git commit -m "test: add CopyIn inside-transaction integration test"
```

---

## Task 18: README — document the new API

**Files:**
- Modify: `readme.md`

- [ ] **Step 1: Add a new section**

After whichever existing section makes sense (after `exec` examples, or as a new top-level "Bulk insert" section), add:

````markdown
## Bulk insert (COPY)

For high-throughput inserts, pg.zig supports the PostgreSQL **COPY FROM
STDIN BINARY** sub-protocol. There are three layered entry points:

```zig
const Row = struct { id: i32, name: []const u8, created_at: i64 };
const rows: []const Row = &.{
    .{ .id = 1, .name = "Alice", .created_at = 1_700_000_000 },
    .{ .id = 2, .name = "Bob",   .created_at = 1_700_000_001 },
};

// Most ergonomic: field names are used as column names.
_ = try conn.copyIntoTable("users", rows);

// Same data with caller-supplied SQL (e.g. for schema-qualified names).
_ = try conn.copyInto(
    "copy users (id, name, created_at) from stdin binary",
    rows,
);

// Streaming primitive (no need to materialise all rows in memory).
var copy = try conn.copyIn(
    "copy users (id, name, created_at) from stdin binary",
    .{ i32, []const u8, i64 },
);
defer copy.deinit();
while (try iter.next()) |item| {
    try copy.writeRow(.{ item.id, item.name, item.ts });
}
const affected = try copy.finish();
```

The streaming primitive automatically flushes its internal buffer when it
exceeds 64 KiB (configurable via `copyInOpts(..., .{ .flush_threshold = N })`).
Forgetting to call `finish` causes `deinit` to send `CopyFail`, which
PostgreSQL treats as an abort — no rows are committed.

Supported column types are the same primitive set the parameter-bind path
supports (`bool`, `i16`/`u16`, `i32`/`u32`, `i64`/`u64`, `f32`, `f64`,
`[]const u8`, fixed-size byte arrays, and the `?T` form for nullable
columns). Only the **binary** wire format is supported in this version.
````

- [ ] **Step 2: Commit**

```bash
git add readme.md
git commit -m "docs: document COPY FROM STDIN binary API in readme"
```

---

## Task 19: Push branch and confirm fork-only push

**Files:** none

- [ ] **Step 1: Push the branch to the fork**

```bash
git push origin feature/copy-binary-design
```

Expected: the push goes to `https://github.com/N283T/pg.zig.git` (the fork). Confirm in the output.

- [ ] **Step 2: Confirm `upstream` push is blocked**

```bash
git push upstream feature/copy-binary-design 2>&1 | head -3
```

Expected: error mentioning `DISABLED-NO-PUSH-TO-UPSTREAM` (the deliberate sentinel set during fork setup). If by any chance it succeeds, **stop** and re-run `git remote set-url --push upstream DISABLED-NO-PUSH-TO-UPSTREAM`.

- [ ] **Step 3: No commit (this task only verifies the push surface).**

---

## Task 20 (Optional, deferrable): Benchmark example

**Files:**
- Create: `example/copy_bench.zig`
- Modify: `example/build.zig`

- [ ] **Step 1: Implement a minimal benchmark comparing INSERT vs `copyIntoTable`**

`example/copy_bench.zig`:

```zig
const std = @import("std");
const pg = @import("pg");

const Row = struct { id: i32, name: []const u8 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conn = try pg.Conn.open(allocator, .{});
    defer conn.deinit();
    try conn.auth(.{ .username = "postgres", .database = "postgres" });

    _ = try conn.exec("drop table if exists bench", .{});
    _ = try conn.exec("create table bench (id int4 not null, name text not null)", .{});

    const N: i32 = 1_000_000;
    var rows = try allocator.alloc(Row, @intCast(N));
    defer allocator.free(rows);
    for (rows, 0..) |*r, i| {
        r.* = .{ .id = @intCast(i), .name = "x" };
    }

    var t1 = try std.time.Timer.start();
    _ = try conn.copyIntoTable("bench", rows);
    const copy_ns = t1.read();
    std.debug.print("COPY binary: {d} rows in {d:.2}ms\n", .{ N, @as(f64, @floatFromInt(copy_ns)) / 1e6 });

    _ = try conn.exec("truncate bench", .{});

    // Naive INSERT comparison
    var t2 = try std.time.Timer.start();
    for (rows) |r| {
        _ = try conn.exec("insert into bench (id, name) values ($1, $2)", .{ r.id, r.name });
    }
    const insert_ns = t2.read();
    std.debug.print("INSERT:      {d} rows in {d:.2}ms\n", .{ N, @as(f64, @floatFromInt(insert_ns)) / 1e6 });
}
```

- [ ] **Step 2: Wire it into `example/build.zig`** (add an executable named `copy_bench` mirroring the existing `main` setup).

- [ ] **Step 3: Run and record the numbers in the README.**

```bash
cd example && zig build run-copy_bench
```

- [ ] **Step 4: Commit**

```bash
git add example/copy_bench.zig example/build.zig readme.md
git commit -m "bench: add COPY-vs-INSERT benchmark example"
```

> NOTE: This task is **optional** and may be deferred to a follow-up PR. It exists to validate the 64 KiB flush threshold and produce a number for the README; the feature itself ships without it.

---

## Self-Review Notes

- **Spec coverage:** every numbered item in the spec maps to at least one task: §3.1–3.4 → Tasks 8, 10, 12, 13; §4 → Tasks 2–13; §5 → Tasks 9, 10; §6 → Task 6; §7 → Tasks 9 (deinit), 10 (start error), 16 (other paths); §8 → Tasks 11, 14–17, 20.
- **Placeholders:** every code step contains complete code. Three `NOTE:` callouts flag spots where the implementer must re-read existing code to confirm an exact API name (`startFlow` signature, `t.authOpts` helper, `row.isNull` API). These are not placeholders — they are explicit integration points where the existing repo is the source of truth.
- **Type / name consistency:** `CopyIn`, `CopyOpts`, `copyIn`, `copyInOpts`, `copyInto`, `copyIntoOpts`, `copyIntoTable`, `copyIntoTableOpts` are used uniformly. Internal helpers (`writeHeader`, `writeRowInto`, `writeFooter`, `copyIntoImpl`, `copyIntoTableImpl`, `buildCopySql`, `fieldTypesValue`) are referenced consistently.
- **Order:** TDD (failing test → implementation → green) is followed for every behaviour-bearing task. Re-exports and integration points are batched into single commits to avoid noise.
