#!/usr/bin/env bash
# Local PostgreSQL test environment using Nix (no Docker / podman required).
#
# Usage:
#   tests/run-pg.sh init     # one-time: initdb + ssl certs + start
#   tests/run-pg.sh start    # start an already-initialized cluster
#   tests/run-pg.sh stop     # stop the cluster
#   tests/run-pg.sh status   # show whether the cluster is running
#   tests/run-pg.sh reset    # stop, wipe pgdata, re-init
#
# The cluster lives in tests/pgdata/ (gitignored) and listens on 127.0.0.1:5432.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGDATA="${SCRIPT_DIR}/pgdata"
LOG_FILE="${SCRIPT_DIR}/pg.log"
NIX_BIN="${NIX_BIN:-/nix/var/nix/profiles/default/bin/nix}"

run_in_nix() {
  "${NIX_BIN}" shell nixpkgs#postgresql_16 nixpkgs#openssl --command "$@"
}

ensure_ssl() {
  local crt="${SCRIPT_DIR}/server.crt"
  local key="${SCRIPT_DIR}/server.key"
  if [[ -f "${crt}" && -f "${key}" ]]; then return; fi
  echo "== Generating SSL server certs =="
  run_in_nix bash -c "
    cd '${SCRIPT_DIR}'
    openssl req -days 3650 -new -text -nodes \
      -subj '/C=SG/ST=SG/L=SG/O=Personal/OU=Personal/CN=localhost' \
      -keyout server.key -out server.csr
    openssl req -days 3650 -x509 -text -in server.csr -key server.key -out server.crt
    rm server.csr
    cp server.crt root.crt
    openssl req -days 3650 -new -nodes \
      -subj '/C=SG/ST=SG/L=SG/O=Personal/OU=Personal/CN=localhost/CN=testclient1' \
      -keyout client.key -out client.csr
    openssl x509 -days 3650 -req -CAcreateserial -in client.csr \
      -CA root.crt -CAkey server.key -out client.crt
    rm client.csr
    chmod 600 server.key client.key
  "
}

cmd_init() {
  if [[ -d "${PGDATA}" ]]; then
    echo "PGDATA already exists at ${PGDATA}; use 'reset' to wipe."
    exit 1
  fi
  ensure_ssl
  echo "== initdb =="
  run_in_nix bash -c "initdb -D '${PGDATA}' --locale=C --encoding=UTF8 -U postgres --auth=trust > /dev/null"

  # Replace the generated configs with our test configs (paths absolute).
  cp "${SCRIPT_DIR}/postgresql.conf" "${PGDATA}/postgresql.conf"
  cp "${SCRIPT_DIR}/pg_hba.conf" "${PGDATA}/pg_hba.conf"

  # Inline absolute SSL paths so we don't need init_ssl.sql.
  cat >> "${PGDATA}/postgresql.conf" <<EOF

# --- appended by tests/run-pg.sh ---
ssl = on
ssl_ca_file = '${SCRIPT_DIR}/root.crt'
ssl_cert_file = '${SCRIPT_DIR}/server.crt'
ssl_key_file = '${SCRIPT_DIR}/server.key'
unix_socket_directories = '${PGDATA}'
EOF

  cmd_start
}

cmd_start() {
  if cmd_status_quiet; then
    echo "PostgreSQL already running."
    return
  fi
  echo "== starting PG =="
  run_in_nix bash -c "pg_ctl -D '${PGDATA}' -l '${LOG_FILE}' start"
  echo "Logs: ${LOG_FILE}"
}

cmd_stop() {
  run_in_nix bash -c "pg_ctl -D '${PGDATA}' stop -m fast" || true
}

cmd_status_quiet() {
  run_in_nix bash -c "pg_ctl -D '${PGDATA}' status >/dev/null 2>&1"
}

cmd_status() {
  run_in_nix bash -c "pg_ctl -D '${PGDATA}' status" || true
}

cmd_reset() {
  cmd_stop || true
  rm -rf "${PGDATA}"
  cmd_init
}

case "${1:-}" in
  init) cmd_init ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  reset) cmd_reset ;;
  *)
    echo "Usage: $0 {init|start|stop|status|reset}"
    exit 1
    ;;
esac
