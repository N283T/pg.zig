# pg.zig: COPY FROM STDIN (binary) Support — Design

- **Date**: 2026-04-15
- **Status**: Approved (pre-implementation)
- **Author**: kitakami0407@gmail.com
- **Target repo**: fork of `github.com/karlseguin/pg.zig`

## 1. Goal

Add support for the PostgreSQL **COPY FROM STDIN** sub-protocol using the
**binary** wire format, exposed through an idiomatic streaming + helper API.
The goal is to make bulk inserts from in-memory Zig values **dramatically
faster** than the current parameterised `INSERT` path while staying consistent
with pg.zig's existing API style and code organisation.

Non-goals (deliberately out of scope for v1):

- COPY TO STDOUT
- COPY ... FROM STDIN with `text` / `csv` formats
- text-format options (`HEADER`, custom `DELIMITER`, `QUOTE`, etc.)
- Non-blocking / pipelined / streaming-replication COPY (`CopyBoth`)
- Per-row recoverable errors (skip-on-error)

## 2. Background

PostgreSQL's frontend/backend protocol exposes a sub-protocol for COPY:

1. Client sends a normal `Query` (`'Q'`) message containing the SQL
   `COPY <table> (...) FROM STDIN BINARY`.
2. Server replies with `CopyInResponse` (`'G'`) signalling readiness.
3. Client streams `CopyData` (`'d'`) messages whose payload is the binary
   COPY stream described in the PostgreSQL docs.
4. Client ends the stream with `CopyDone` (`'c'`), or aborts with
   `CopyFail` (`'f'`).
5. Server replies with `CommandComplete` (`'C'`) followed by
   `ReadyForQuery` (`'Z'`).

The binary stream itself has the layout:

```
PGCOPY\n\xff\r\n\0       (11-byte signature)
00 00 00 00              (i32 flags, must be 0)
00 00 00 00              (i32 header extension length, must be 0)
[ rows ... ]
ff ff                    (i16 -1, terminator)
```

Each row:

```
[i16 num_columns]
repeat num_columns times:
  [i32 length]            (-1 means NULL, no value bytes follow)
  [length bytes payload]
```

Reference implementations confirming this layout:
- `rust-postgres` — `tokio-postgres/src/binary_copy.rs`
- `pgx` (Go) — `copy_from.go`
- libpq — `src/interfaces/libpq/fe-protocol3.c`

## 3. API Surface

Three public entry points are added to `Conn`, layered from primitive to
convenience:

### 3.1 Primitive — `Conn.copyIn`

```zig
pub fn copyIn(
    self: *Conn,
    sql: []const u8,
    comptime ColumnTypes: anytype, // e.g. .{ i32, []const u8, i64 }
) !CopyIn(ColumnTypes)
```

`ColumnTypes` is a comptime tuple of Zig types describing each column, in
order. This lets `writeRow` be type-checked at compile time and lets each
column's encoder be `inline for`-expanded with no per-row dispatch cost.

`CopyIn(ColumnTypes)` is a generic struct returned by value (caller owns):

```zig
pub fn writeRow(self: *Self, values: anytype) !void;
pub fn flush(self: *Self) !void;          // explicit flush; usually automatic
pub fn finish(self: *Self) !i64;          // CopyDone, returns affected rows
pub fn cancel(self: *Self, reason: []const u8) !void;
pub fn deinit(self: *Self) void;          // auto-cancel if not finished
```

`values` must be a tuple/struct literal whose field count and types match
`ColumnTypes`. A mismatch is a compile-time error.

### 3.2 Slice helper — `Conn.copyInto`

```zig
pub fn copyInto(
    self: *Conn,
    sql: []const u8,
    rows: anytype, // []const SomeStruct (or pointer to array)
) !i64
```

Internally derives `ColumnTypes` from the struct fields of the element type
in declaration order, opens a `CopyIn`, writes each row, and finishes.

### 3.3 Table helper — `Conn.copyIntoTable`

```zig
pub fn copyIntoTable(
    self: *Conn,
    table: []const u8,
    rows: anytype, // []const SomeStruct
) !i64
```

Generates the SQL string `COPY "<table>" ("<f1>","<f2>",...) FROM STDIN
BINARY` from the struct's field names. Field names are double-quoted to
preserve case and survive reserved words. Schema-qualified names should
be passed already quoted by the caller (e.g. `"public\".\"users"`), or use
`copyInto` directly.

### 3.4 Usage examples

```zig
// Most ergonomic — fields = column names
const Row = struct { id: i32, name: []const u8, created_at: i64 };
const rows: []const Row = &.{
    .{ .id = 1, .name = "Alice", .created_at = 1_700_000_000 },
    .{ .id = 2, .name = "Bob",   .created_at = 1_700_000_001 },
};
const n = try conn.copyIntoTable("users", rows);

// User-supplied SQL (column reordering, schema, etc.)
_ = try conn.copyInto(
    "COPY users (id, name, created_at) FROM STDIN BINARY",
    rows,
);

// Streaming primitive — does not require holding all rows in memory
var copy = try conn.copyIn(
    "COPY users (id, name, created_at) FROM STDIN BINARY",
    .{ i32, []const u8, i64 },
);
defer copy.deinit();
while (try iter.next()) |item| {
    try copy.writeRow(.{ item.id, item.name, item.ts });
}
const n = try copy.finish();
```

## 4. Architecture

### 4.1 New files

- `src/copy.zig` — `CopyIn(comptime ColumnTypes)` generic struct, the
  `Conn.copyIn` / `copyInto` / `copyIntoTable` method bodies, and the
  comptime helpers (`fieldTypesTuple`, struct→tuple conversion, SQL
  generation). Tests live at the bottom of the same file in pg.zig style.
- `src/proto/CopyData.zig` — serialiser for `'d'`.
- `src/proto/CopyDone.zig` — serialiser for `'c'`.
- `src/proto/CopyFail.zig` — serialiser for `'f'`.

### 4.2 Modified files

- `src/conn.zig`
  - Add `copy_in` to the `Conn.State` enum.
  - Add the three public methods plus their `*Opts` variants (delegating
    to `src/copy.zig`).
  - Make `_buf`, `_reader`, `_state`, `read`, `write`, `unexpectedDBMessage`,
    `setErr`, `readyForQuery` accessible as needed (most are already `pub`).
- `src/proto.zig` — re-export the three new proto structs.
- `src/lib.zig` — re-export `CopyIn`.
- `src/pg.zig` — re-export `CopyIn` so `@import("pg")` users see it.
- `src/types.zig` — extract or expose the existing per-type binary encoders
  in a form the COPY path can call as `encodeBinary(comptime T, writer,
  value) !void`. The Bind path keeps using them; only the call site changes.
- `readme.md` — add a "Bulk insert (COPY)" section with a short example and
  a note about format support.
- `tests/` — no new infra; the existing compose stack is sufficient.

### 4.3 Responsibility split

- `Conn` owns connection state transitions, reading server replies, and
  exposing `read`/`write` primitives. It does **not** know the binary COPY
  payload format.
- `CopyIn` owns the COPY payload buffer (header, rows, footer), the per-row
  type-driven encoding, and the flush threshold. It calls `Conn.write` only
  through `CopyData`.
- `proto/Copy*` each handle exactly one wire message kind (single
  responsibility, mirrors existing `Query.zig` etc.).

## 5. Wire Protocol Flow

### 5.1 Start (`copyIn`)

1. Verify `Conn._state` is `idle` or `transaction`; otherwise return
   `error.ConnectionBusy`.
2. Reset `Conn._buf`, write a `Query` message containing the user's SQL,
   send it, set `_state = .copy_in`.
3. Read replies via `Conn.read()`:
   - `'G'` (CopyInResponse) — consume payload, construct and return
     `CopyIn`. Validate that the server-reported overall format is binary
     (byte 0 of the payload = 1).
   - `'E'` (Error) — `setErr` is already called by `read`; drain to `'Z'`,
     restore `_state`, propagate `error.PG`.
   - other — `unexpectedDBMessage`.
4. The returned `CopyIn` initialises its internal buffer with the 19-byte
   binary header (`MAGIC + i32(0) + i32(0)`).

### 5.2 Per-row (`writeRow`)

For each call:

1. Append `i16 num_columns`.
2. `inline for` over `ColumnTypes`, calling
   `types.encodeBinary(T, &self.buf, values[i])` per column. The encoder is
   responsible for writing the `i32 length` prefix and the value bytes (or
   length `-1` for null `?T`).
3. If the buffered payload exceeds `flush_threshold` bytes, wrap the buffer
   in a `CopyData` message, write it via `Conn.write`, and reset the
   buffer ready for the next batch (preserving zero rows in flight).

`flush_threshold` defaults to **64 KiB** and is configurable via a new
`CopyOpts { flush_threshold: usize = 64 * 1024 }` passed to a
`copyInOpts` / `copyIntoOpts` / `copyIntoTableOpts` variant of each
public method (mirroring pg.zig's existing `*Opts` convention).
Rationale: rust-postgres uses 4 KiB which is
conservative for sustained throughput; pgx batches per call; 64 KiB is a
reasonable middle ground that amortises syscalls without ballooning peak
memory. A per-call benchmark in `example/` will validate before merge.

### 5.3 Finish (`finish`)

1. Append the binary footer `i16 -1` to the buffer.
2. Send the remaining buffer as a final `CopyData`.
3. Send `CopyDone` (`'c'`).
4. Read replies:
   - `'C'` (CommandComplete) — parse with existing `proto.CommandComplete`,
     remember rows-affected.
   - `'Z'` (ReadyForQuery) — `_state` is restored automatically by
     `Conn.read`; return the rows-affected count.
   - `'E'` (Error) — drain to `'Z'`, propagate `error.PG`.
   - other — `unexpectedDBMessage`.

### 5.4 Cancel (`cancel`)

1. Send `CopyFail` (`'f'`) with the supplied reason.
2. Read until `'Z'`. The server is required to respond with an error and
   then `ReadyForQuery`; the resulting `'E'` is **expected** and is not
   surfaced to the caller as an error.
3. Restore `_state` (handled by `Conn.read` on `'Z'`).

### 5.5 deinit auto-cancel

If `finish` and `cancel` were not called before `deinit`:

- Best-effort `cancel("aborted by deinit")`.
- On any failure, set `_state = .fail` and let the pool dispose of the
  connection. This matches pg.zig's existing failure model.

### 5.6 Connection state

A new state `.copy_in` is added to `Conn.State`. While in this state,
`canQuery` returns false, so `query`/`exec`/`copyIn` all return
`ConnectionBusy`. The state returns to whatever the next `'Z'` reports
(`.idle` or `.transaction`).

## 6. Type Encoding

### 6.1 Reuse Bind encoders

pg.zig's parameter Bind path already encodes Zig values to PostgreSQL's
binary format with the same per-value layout (`i32 length` prefix, then
value bytes; `-1` for NULL). The COPY implementation **reuses** those
encoders rather than reimplementing them.

The expected refactor in `types.zig` is minimal: introduce a
`pub fn encodeBinary(comptime T: type, buf: *Buffer, value: T) !void` that
the Bind path also calls, with the `format code` array (which is
Bind-specific) handled separately. If the existing functions are already
shaped this way, only visibility / re-exports change.

### 6.2 Supported Zig types in v1

| Zig type | PG type | Notes |
|---|---|---|
| `bool` | bool | 1 byte (0 / 1) |
| `i16` / `u16` | int2 | 2 bytes BE |
| `i32` / `u32` | int4 | 4 bytes BE |
| `i64` / `u64` | int8 | 8 bytes BE |
| `f32` | float4 | 4 bytes BE |
| `f64` | float8 | 8 bytes BE |
| `[]const u8`, `[]u8` | text / bytea / varchar | bytes verbatim (length prefix + payload) |
| `[N]u8` | uuid / fixed bytea | fixed-size byte array |
| `?T` | nullable | length `-1` for null, otherwise `T`'s encoding |

Anything not in this table is unsupported by `writeCopyValue` and
produces a compile-time error.

### 6.3 Deferred to follow-up

- `[]const T` (arrays of scalar types)
- `Numeric` (arbitrary-precision decimals)
- `Cidr` / `Inet` (network types)
- User structs with custom `pgEncode`

These types are encoded by the Bind path today but not by
`writeCopyValue`. Adding them is mechanical (one additional `switch` arm
per type in `writeCopyValue`) and can land as follow-up PRs once v1
ships.

### 6.4 NULL handling

The Bind path's `?T` convention is reused: a null optional writes
`i32 -1` and no value bytes. Non-optional `T` always writes a value.

### 6.5 Compile-time expansion

`writeRow` is `inline for`-unrolled across `ColumnTypes`, so the per-row
hot path is a straight-line sequence of buffer writes with no runtime
type switching.

## 7. Error Handling

| Situation | Behaviour |
|---|---|
| Server error at `copyIn` start (e.g. table not found) | Drain to `'Z'`, return `error.PG`, `Conn.err` populated, `_state` restored. |
| `writeRow` value/type mismatch | Compile-time error (tuple length / type mismatch is caught by `inline for` over `ColumnTypes`). |
| Network write failure during streaming | `_state = .fail`, error propagated, pool disposes connection. |
| Server error at `finish` (constraint violation, type mismatch on server side) | Drain to `'Z'`, return `error.PG`, `Conn.err` populated. |
| Server error response after `cancel` | Expected; not surfaced as an error. |
| `deinit` without `finish` / `cancel` | Best-effort `cancel`; on failure `_state = .fail`. |
| Calling `copyIn` while `_state == .copy_in` (or `.fail`, `.query`) | `error.ConnectionBusy`. |

## 8. Testing Strategy

### 8.1 Unit tests (no PG required)

Located alongside the new proto files:

- `proto/CopyData.zig`: writes `'d' [i32 len] [payload]`.
- `proto/CopyDone.zig`: writes `'c' 00 00 00 04`.
- `proto/CopyFail.zig`: writes `'f' [i32 len] reason\0`.
- `copy.zig`: header bytes are exactly `PGCOPY\n\xff\r\n\0` + 8 zero bytes;
  footer is `\xff\xff`; row encoding round-trips against a reference byte
  string for a small fixed example.

### 8.2 Integration tests (uses `tests/compose.yml`)

In `src/copy.zig` `test` blocks:

1. Happy path: `copyIntoTable` for 1000 rows; verify with
   `SELECT count(*)`.
2. Mixed nullable types (`?i32`, `?[]const u8`) including null values;
   verify each value with `SELECT`.
3. Large volume: 100 000 rows to force multiple flushes; verify count.
4. All supported types: one column per supported PG type in a single
   table; round-trip via `SELECT` and assert each value.
5. Empty: `finish` with zero rows; affected = 0; table unchanged.
6. Server error at start (unknown table): expect `error.PG`, `conn.err`
   populated, follow-up `exec` succeeds (connection recovered).
7. Server error at finish (NOT NULL violation): expect `error.PG`,
   follow-up `exec` succeeds.
8. `cancel("test")` after several rows: expect success, table empty,
   follow-up `exec` succeeds.
9. `deinit` without `finish`: connection still usable (re-acquire from
   pool, run a query).
10. Inside transaction: `BEGIN` → `copyIntoTable` → `ROLLBACK`; verify
    rows are gone.

### 8.3 Benchmark (optional, in `example/`)

A new `example/copy_bench.zig` (or sub-target) compares 1 000 000-row
insert via `INSERT` (parameterised) vs `copyIntoTable`, prints elapsed
time and throughput. Used to validate the 64 KiB flush threshold and to
populate a number for the README.

## 9. Fork Strategy

- Fork `github.com/karlseguin/pg.zig` to the user's account on GitHub.
- Develop on a feature branch `feature/copy-binary` in the fork.
- Open the PR upstream (Karl Seguin) once feature, tests, and docs are in
  place; if upstream declines, the fork stands on its own.
- Code style strictly matches the existing repo: no doc comments unless
  a non-obvious invariant needs explanation, English identifiers /
  comments / commit messages, conventional commit prefixes
  (`feat:` / `fix:` / `docs:` / `test:`).

## 10. Open Questions / Risks

- **`types.zig` refactor scope** — the cleanest way to expose binary
  encoders to COPY may touch more of the file than expected. Mitigation:
  start with a thin wrapper that calls the existing private functions
  (or re-uses the same code paths) without restructuring; refactor only
  if duplication becomes painful.
- **Flush threshold tuning** — 64 KiB is a guess. The benchmark in §8.3
  is the gate that confirms it before merge. Acceptable range: 4 KiB
  (rust-postgres) to 256 KiB.
- **Schema-qualified table names in `copyIntoTable`** — current design
  defers to the caller. If this proves error-prone, a follow-up can
  accept `(schema, table)` separately.
- **Listener interaction** — pg.zig's `Listener` shares the connection
  primitives; verify that adding `_state.copy_in` does not break
  `Listener` (which should never enter that state, but the enum
  exhaustiveness needs to compile).
