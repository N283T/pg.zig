#!/usr/bin/env bash
# hyperfine-driven cross-client COPY benchmark.
#
# Wraps the three pre-built binaries (pg.zig / pgx / rust-postgres) with
# hyperfine for warm-up + iteration averaging + statistical summary
# (mean, stddev, min, max, relative).
#
# Each wrapped binary performs its full sequence internally — connect,
# create/truncate the target table, run COPY for three sizes
# (1k / 10k / 100k), disconnect — so hyperfine's reported duration is
# the aggregate of all three sizes, not per-size. Good enough for a
# first statistical pass; use bench.sh for per-size numbers.
#
# Usage:
#   benchmarks/bench_hyperfine.sh
#
# Env: libpq vars (PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ZIG_BIN="${ROOT_DIR}/zig-out/bin/copy_bench"
PGX_BIN="${SCRIPT_DIR}/pgx_bench/pgx_bench"
RUST_BIN="${SCRIPT_DIR}/rust_bench/target/release/rust_bench"

echo "== building all three in release mode =="
# `zig build install` builds and installs without running the bench step
# (which would execute the binary serially before hyperfine takes over).
(cd "${ROOT_DIR}" && zig build install -Doptimize=ReleaseFast)
if [[ ! -x "${ZIG_BIN}" ]]; then
  echo "zig-out/bin/copy_bench not found after 'zig build install'" >&2
  exit 1
fi
(cd "${SCRIPT_DIR}/pgx_bench" && go build -o pgx_bench .)
(cd "${SCRIPT_DIR}/rust_bench" && cargo build --release --quiet)

echo "== hyperfine (warmup 3, runs 10) =="
# BENCH_COPY_ONLY=1 tells the pg.zig bench to skip the (slow) INSERT-in-tx
# baseline so its workload matches the pgx / rust-postgres binaries,
# which only measure COPY.
hyperfine \
  --warmup 3 \
  --runs 10 \
  --export-markdown "${SCRIPT_DIR}/hyperfine-results.md" \
  -n pg.zig        "env BENCH_COPY_ONLY=1 ${ZIG_BIN}" \
  -n pgx           "${PGX_BIN}" \
  -n rust-postgres "${RUST_BIN}"

echo
echo "Markdown summary written to ${SCRIPT_DIR}/hyperfine-results.md"
