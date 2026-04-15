#!/usr/bin/env bash
# Cross-client COPY benchmark orchestrator.
#
# Builds and runs the three per-client benchmarks (pg.zig, pgx, rust-postgres)
# against the same local PostgreSQL instance, collecting CSV lines
# (CLIENT,SIZE,DURATION_MS,ROWS_PER_SEC) and printing a merged table.
#
# Usage:
#   benchmarks/bench.sh          # all clients
#   benchmarks/bench.sh zig      # just pg.zig
#   benchmarks/bench.sh zig rust # subset
#
# Env: standard libpq vars (PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD)
# are honoured by every client.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default to all three clients if nothing specified.
if [[ $# -eq 0 ]]; then
  CLIENTS=(zig pgx rust)
else
  CLIENTS=("$@")
fi

declare -a RESULTS

bench_zig() {
  echo "== pg.zig (zig build bench -Doptimize=ReleaseFast) ==" >&2
  (cd "${ROOT_DIR}" && zig build bench -Doptimize=ReleaseFast) > /tmp/pgzig-bench-zig.txt 2>&1
  # zig bench prints a human table; convert into the shared CSV format.
  # Column layout: size strategy duration "ms" rows_per_sec relative.
  awk '
    /^[0-9]+[[:space:]]+copy_into/ {
      printf "pg.zig,%d,%.3f,%.0f\n", $1, $3, $5
    }
  ' /tmp/pgzig-bench-zig.txt
}

bench_pgx() {
  echo "== pgx ==" >&2
  (cd "${SCRIPT_DIR}/pgx_bench" && go build -o pgx_bench . && ./pgx_bench)
}

bench_rust() {
  echo "== rust-postgres ==" >&2
  (cd "${SCRIPT_DIR}/rust_bench" && cargo build --release --quiet && ./target/release/rust_bench)
}

for client in "${CLIENTS[@]}"; do
  case "${client}" in
    zig)  out=$(bench_zig) ;;
    pgx)  out=$(bench_pgx) ;;
    rust) out=$(bench_rust) ;;
    *) echo "unknown client: ${client}" >&2; exit 1 ;;
  esac
  while IFS= read -r line; do
    [[ -n "${line}" ]] && RESULTS+=("${line}")
  done <<< "${out}"
done

# Print merged table, grouped by size.
echo
printf '%-16s %10s %14s %14s\n' client size duration_ms rows_per_sec
printf '%s\n' "----------------------------------------------------------"
for size in 1000 10000 100000; do
  for line in "${RESULTS[@]}"; do
    IFS=',' read -r client lsize ms rps <<< "${line}"
    if [[ "${lsize}" == "${size}" ]]; then
      printf '%-16s %10d %14.3f %14.0f\n' "${client}" "${lsize}" "${ms}" "${rps}"
    fi
  done
  echo
done
