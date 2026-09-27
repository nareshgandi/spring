#!/usr/bin/env bash
# One scenario.
# Usage: [FIX=none|track|reset] [RO_MODE=always|transaction] ./run.sh [spring|jdbc|explicit|none] [seconds]
#   spring   : Spring Boot + HikariCP + @Transactional(readOnly = true)  (customer's real path)
#   jdbc     : plain JDBC setReadOnly(true) through HikariCP
#   explicit : raw SET default_transaction_read_only = on/off
#   none     : control, readers never touch read-only
# Env:   DB_PORT=5432  PGB_PORT=6433  MAVEN_REPO=<mirror>  PGJDBC_VERSION=<spring build only>
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-explicit}"
SECS="${2:-20}"
FIX="${FIX:-none}"
export RO_MODE="${RO_MODE:-always}"
DB_PORT="${DB_PORT:-5432}"
export PGB_PORT="${PGB_PORT:-6433}"
W=/tmp/pgb-repro
M="${MAVEN_REPO:-https://repo1.maven.org/maven2}"
JAR=spring-app/target/readonly-repro.jar

[ "$(id -u)" -ne 0 ] || { echo "Run as a normal user - pgbouncer refuses to run as root"; exit 1; }
command -v pgbouncer >/dev/null || { echo "pgbouncer not found - run: sudo ./install-centos.sh"; exit 1; }
command -v javac     >/dev/null || { echo "JDK not found - install java-17-openjdk-devel"; exit 1; }

mkdir -p lib "$W"

if [ "$MODE" = "spring" ]; then
  if [ ! -f "$JAR" ] || [ -n "${PGJDBC_VERSION:-}" ]; then ./build-spring.sh; fi
else
  dl() { local f="lib/$(basename "$1")"; [ -s "$f" ] || curl -fsSL -o "$f" "$M/$1"; }
  dl com/zaxxer/HikariCP/5.1.0/HikariCP-5.1.0.jar
  dl org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar
  dl org/slf4j/slf4j-api/2.0.13/slf4j-api-2.0.13.jar
  dl org/slf4j/slf4j-nop/2.0.13/slf4j-nop-2.0.13.jar
fi

# ---- pgbouncer config for this scenario
cp userlist.txt "$W/userlist.txt"; chmod 600 "$W/userlist.txt"
sed -e "s/@DB_PORT@/$DB_PORT/" -e "s/@PGB_PORT@/$PGB_PORT/" pgbouncer.ini > "$W/pgbouncer.ini"
case "$FIX" in
  none)  ;;
  track) echo "track_extra_parameters = default_transaction_read_only" >> "$W/pgbouncer.ini" ;;
  reset) sed -i -e 's/^server_reset_query = .*/server_reset_query = RESET default_transaction_read_only/' \
                -e 's/^server_reset_query_always = .*/server_reset_query_always = 1/' "$W/pgbouncer.ini" ;;
  *)     echo "FIX must be none|track|reset"; exit 1 ;;
esac

# ---- (re)start pgbouncer so no polluted server connections survive between scenarios
stop_pgb() {
  if [ -f "$W/pgbouncer.pid" ]; then
    kill "$(cat "$W/pgbouncer.pid")" 2>/dev/null || true
    for _ in 1 2 3 4 5; do [ -f "$W/pgbouncer.pid" ] || break; sleep 1; done
    rm -f "$W/pgbouncer.pid"
  fi
}
stop_pgb
: > "$W/pgbouncer.log"
if ! pgbouncer -d "$W/pgbouncer.ini"; then
  echo "pgbouncer failed to start. Log:"; tail -20 "$W/pgbouncer.log"; exit 2
fi
trap stop_pgb EXIT
sleep 1
if [ ! -f "$W/pgbouncer.pid" ]; then
  echo "pgbouncer exited. Log (FIX=track needs PgBouncer >= 1.20):"; tail -20 "$W/pgbouncer.log"; exit 2
fi

echo "==== FIX=$FIX MODE=$MODE RO_MODE=$RO_MODE  $(pgbouncer -V | head -1)"
grep -E '^(pool_mode|server_reset_query|server_reset_query_always|track_extra_parameters)' "$W/pgbouncer.ini" | sed 's/^/     /'

if [ "$MODE" = "spring" ]; then
  java -jar "$JAR" --repro.seconds="$SECS"
else
  java -cp "lib/*" Repro.java "$MODE" "$SECS"
fi
