// Cross-client COPY benchmark: pgx version.
//
// Measures conn.CopyFrom for the same 3-column schema used by the Zig
// and Rust benches in this directory. Prints one line in the shared
// format understood by bench.sh.
//
// Defaults: 127.0.0.1:5432, user=postgres, db=postgres, no password.
// Override via PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD.
package main

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
)

type Row struct {
	ID   int32
	Name string
	Ts   int64
}

var sizes = []int{1_000, 10_000, 100_000}

func main() {
	ctx := context.Background()

	conn, err := pgx.Connect(ctx, buildConnString())
	if err != nil {
		die("connect: %v", err)
	}
	defer conn.Close(ctx)

	if _, err := conn.Exec(ctx, "drop table if exists bench_copy"); err != nil {
		die("drop: %v", err)
	}
	if _, err := conn.Exec(ctx,
		"create table bench_copy (id int4 not null, name text not null, ts int8 not null)",
	); err != nil {
		die("create: %v", err)
	}
	defer conn.Exec(ctx, "drop table if exists bench_copy")

	for _, n := range sizes {
		rows := buildRows(n)

		if _, err := conn.Exec(ctx, "truncate table bench_copy"); err != nil {
			die("truncate: %v", err)
		}

		start := time.Now()
		inserted, err := conn.CopyFrom(
			ctx,
			pgx.Identifier{"bench_copy"},
			[]string{"id", "name", "ts"},
			pgx.CopyFromSlice(len(rows), func(i int) ([]any, error) {
				return []any{rows[i].ID, rows[i].Name, rows[i].Ts}, nil
			}),
		)
		elapsed := time.Since(start)
		if err != nil {
			die("copy: %v", err)
		}
		if inserted != int64(len(rows)) {
			die("copy: inserted %d rows, expected %d", inserted, len(rows))
		}

		// Shared output format: CLIENT,SIZE,DURATION_MS,ROWS_PER_SEC
		ms := float64(elapsed.Nanoseconds()) / float64(time.Millisecond)
		rps := float64(n) / elapsed.Seconds()
		fmt.Printf("pgx,%d,%.3f,%.0f\n", n, ms, rps)
	}
}

func buildRows(n int) []Row {
	names := []string{
		"alice", "bob", "carol", "daniel",
		"ellen", "francesco", "gina", "hiroshi",
		"ingrid", "junpei", "kenji", "louisa",
		"maribel", "natalia", "ogawa", "priscilla",
		"some-longer-name-just-to-vary-widths", "short",
	}
	rows := make([]Row, n)
	for i := 0; i < n; i++ {
		rows[i] = Row{
			ID:   int32(i),
			Name: names[i%len(names)],
			Ts:   int64(1_700_000_000) + int64(i),
		}
	}
	return rows
}

func buildConnString() string {
	host := env("PGHOST", "127.0.0.1")
	portStr := env("PGPORT", "5432")
	port, _ := strconv.Atoi(portStr)
	if port == 0 {
		port = 5432
	}
	user := env("PGUSER", "postgres")
	db := env("PGDATABASE", "postgres")
	pass := os.Getenv("PGPASSWORD")

	if pass == "" {
		return fmt.Sprintf("host=%s port=%d user=%s dbname=%s sslmode=disable", host, port, user, db)
	}
	return fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=disable", host, port, user, pass, db)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
