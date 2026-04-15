//! Cross-client COPY benchmark: tokio-postgres version.
//!
//! Measures `BinaryCopyInWriter` throughput on the same 3-column schema
//! used by the Zig and Go benches in this directory. Prints one CSV line
//! per size (pgx-compatible format).
//!
//! Defaults: 127.0.0.1:5432, user=postgres, db=postgres, no password.
//! Override via PGHOST/PGPORT/PGUSER/PGDATABASE/PGPASSWORD.

use std::env;
use std::error::Error;
use std::time::Instant;

use futures_util::pin_mut;
use tokio_postgres::binary_copy::BinaryCopyInWriter;
use tokio_postgres::types::Type;
use tokio_postgres::{Client, NoTls};

const SIZES: [usize; 3] = [1_000, 10_000, 100_000];

#[derive(Clone)]
struct Row {
    id: i32,
    name: String,
    ts: i64,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let (client, connection) = tokio_postgres::connect(&build_conn_string(), NoTls).await?;
    // The driver expects the connection future to be polled.
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("connection error: {}", e);
        }
    });

    client
        .batch_execute(
            "drop table if exists bench_copy;\
             create table bench_copy (id int4 not null, name text not null, ts int8 not null);",
        )
        .await?;

    for &n in &SIZES {
        let rows = build_rows(n);

        client.batch_execute("truncate table bench_copy").await?;

        let (ms, inserted) = run_copy(&client, &rows).await?;
        if inserted as usize != n {
            return Err(format!("copy: inserted {} rows, expected {}", inserted, n).into());
        }

        // Shared CSV format: CLIENT,SIZE,DURATION_MS,ROWS_PER_SEC
        let rps = (n as f64) / (ms / 1000.0);
        println!("rust-postgres,{},{:.3},{:.0}", n, ms, rps);
    }

    client.batch_execute("drop table if exists bench_copy").await?;
    Ok(())
}

async fn run_copy(client: &Client, rows: &[Row]) -> Result<(f64, u64), Box<dyn Error>> {
    let sink = client
        .copy_in("copy bench_copy (id, name, ts) from stdin binary")
        .await?;
    let writer = BinaryCopyInWriter::new(sink, &[Type::INT4, Type::TEXT, Type::INT8]);
    pin_mut!(writer);

    let start = Instant::now();
    for row in rows {
        writer
            .as_mut()
            .write(&[&row.id, &row.name, &row.ts])
            .await?;
    }
    let inserted = writer.as_mut().finish().await?;
    let elapsed = start.elapsed();

    Ok((elapsed.as_secs_f64() * 1000.0, inserted))
}

fn build_rows(n: usize) -> Vec<Row> {
    let names = [
        "alice",
        "bob",
        "carol",
        "daniel",
        "ellen",
        "francesco",
        "gina",
        "hiroshi",
        "ingrid",
        "junpei",
        "kenji",
        "louisa",
        "maribel",
        "natalia",
        "ogawa",
        "priscilla",
        "some-longer-name-just-to-vary-widths",
        "short",
    ];
    (0..n)
        .map(|i| Row {
            id: i as i32,
            name: names[i % names.len()].to_string(),
            ts: 1_700_000_000 + i as i64,
        })
        .collect()
}

fn build_conn_string() -> String {
    let host = env::var("PGHOST").unwrap_or_else(|_| "127.0.0.1".to_string());
    let port = env::var("PGPORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .unwrap_or(5432);
    let user = env::var("PGUSER").unwrap_or_else(|_| "postgres".to_string());
    let db = env::var("PGDATABASE").unwrap_or_else(|_| "postgres".to_string());
    let pass = env::var("PGPASSWORD").ok();

    match pass {
        Some(p) => format!("host={host} port={port} user={user} password={p} dbname={db}"),
        None => format!("host={host} port={port} user={user} dbname={db}"),
    }
}
