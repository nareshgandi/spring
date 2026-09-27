#!/usr/bin/env bash
# Installs everything needed on CentOS Stream / RHEL / Rocky / Alma 8 or 9:
#   PostgreSQL (PGDG), PgBouncer (PGDG), OpenJDK 17 (full JDK), curl
# and creates the repro role/database/table.
#
# Usage:   sudo ./install-centos.sh
# Options: PGVER=16 (default)  |  SKIP_PG=1 (you already run PostgreSQL 14+; only installs pgbouncer + JDK)
set -euo pipefail
cd "$(dirname "$0")"

PGVER="${PGVER:-16}"
SKIP_PG="${SKIP_PG:-0}"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

EL="$(rpm -E %rhel)"
ARCH="$(uname -m)"
case "$EL" in
  8|9) ;;
  7) echo "CentOS 7 is EOL; its repos are archived. Use EL8/EL9 (Rocky/Alma/Stream)."; exit 1 ;;
  *) echo "Unsupported EL version: $EL"; exit 1 ;;
esac

echo "==> Base packages + JDK 17 (-devel is needed: java runs Repro.java from source)"
dnf install -y curl unzip java-17-openjdk-devel

echo "==> PGDG repository"
if ! rpm -q pgdg-redhat-repo >/dev/null 2>&1; then
  dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${EL}-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
fi
# EL8/EL9 appstream ships its own postgresql module; disable it so PGDG packages win
dnf -qy module disable postgresql >/dev/null 2>&1 || true

echo "==> PgBouncer"
dnf install -y pgbouncer
pgbouncer -V | head -1

if [ "$SKIP_PG" = "1" ]; then
  echo "==> SKIP_PG=1: not installing PostgreSQL."
  echo "    Run setup.sql yourself and allow 'host repro repro 127.0.0.1/32 scram-sha-256' in pg_hba.conf"
  exit 0
fi

echo "==> PostgreSQL ${PGVER}"
dnf install -y "postgresql${PGVER}-server" "postgresql${PGVER}"
PGDATA="/var/lib/pgsql/${PGVER}/data"
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  "/usr/pgsql-${PGVER}/bin/postgresql-${PGVER}-setup" initdb
fi
systemctl enable --now "postgresql-${PGVER}"

echo "==> pg_hba: allow repro over 127.0.0.1 with scram (prepended so it matches first)"
HBA="$PGDATA/pg_hba.conf"
if ! grep -q '^host repro repro 127.0.0.1/32' "$HBA"; then
  sed -i '1i host repro repro 127.0.0.1/32 scram-sha-256' "$HBA"
fi
sudo -u postgres psql -qAt -c "SELECT pg_reload_conf();" >/dev/null

echo "==> Creating role/database/table"
sudo -u postgres psql -v ON_ERROR_STOP=1 < setup.sql

echo
echo "Done. Now, as a NORMAL user (not root):"
echo "   ./run-all.sh spring   # Spring @Transactional(readOnly = true): baseline + 3 fixes"
