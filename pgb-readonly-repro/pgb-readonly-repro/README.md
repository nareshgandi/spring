# PgBouncer transaction pooling: "cannot execute INSERT in a read-only transaction"

Reproduces read-only state leaking between clients when a Spring Boot + HikariCP application
using `@Transactional(readOnly = true)` goes through PgBouncer in `pool_mode = transaction`.
It then proves three fixes, none of which needs an application code change.

## Root cause

For `@Transactional(readOnly = true)`, Spring's transaction manager does the following:

| Step | Spring | pgJDBC with `readOnlyMode=always` or an old driver | pgJDBC with `readOnlyMode=transaction` |
|---|---|---|---|
| 1 | `setReadOnly(true)` while autocommit is still on | session-level read-only `SET` (its own transaction) | nothing |
| 2 | `setAutoCommit(false)` | nothing | nothing |
| 3 | first query | `BEGIN` + query | `BEGIN READ ONLY` + query |
| 4 | commit | `COMMIT` | `COMMIT` |
| 5 | `setAutoCommit(true)`, then `setReadOnly(false)` | session-level read-write `SET` (its own transaction) | nothing |

In transaction pooling, steps 1 and 5 can be routed to different server backends. The backend
that received step 1 stays read-only and is later handed to a writer:

```
ERROR: cannot execute INSERT in a read-only transaction   (SQLSTATE 25006)
```

## Fixes demonstrated

| Fix | Where | Change | Notes |
|---|---|---|---|
| A | PgBouncer | `track_extra_parameters = default_transaction_read_only` | PgBouncer 1.20+ and PostgreSQL 14+. Keeps read-only pools read-only. |
| B | PgBouncer | `server_reset_query = RESET default_transaction_read_only` plus `server_reset_query_always = 1` | Any version. One extra round trip per transaction. |
| C | JDBC URL | `readOnlyMode=transaction` | Configuration only. Read-only becomes transaction-scoped. Also the right fix for Cloud SQL Managed Connection Pooling, where A and B are not available. |

## Requirements

CentOS Stream, RHEL, Rocky or Alma 8/9 with internet access to download.postgresql.org,
repo1.maven.org and archive.apache.org.

| Component | Package or source |
|---|---|
| PostgreSQL 14+ | `postgresql16-server` from PGDG |
| PgBouncer | `pgbouncer` from PGDG (1.20+ for Fix A) |
| Java | `java-17-openjdk-devel` (the full JDK) |
| Maven | the system `mvn`, or downloaded automatically into `./tools` by `build-spring.sh` |
| Spring Boot 3.3.5, HikariCP, pgJDBC 42.7.x | Maven Central, downloaded automatically |

## Quick start

```bash
chmod +x *.sh
sudo ./install-centos.sh          # or: sudo SKIP_PG=1 ./install-centos.sh if PostgreSQL 14+ already runs
./run-all.sh spring               # as a normal user, not root
```

Expected summary:

```
Baseline (no fix)                                RESULT: REPRODUCED - N read-only errors leaked to writers
Fix A: track_extra_parameters (PgBouncer)        RESULT: no read-only errors
Fix B: RESET after every txn (PgBouncer)         RESULT: no read-only errors
Fix C: readOnlyMode=transaction (JDBC URL)       RESULT: no read-only errors
```

## Test with the customer's exact driver version

```bash
PGJDBC_VERSION=42.2.27 FIX=none RO_MODE=always ./run.sh spring 30
PGJDBC_VERSION=42.2.27 FIX=none RO_MODE=transaction ./run.sh spring 30
```

Check the customer's version with `mvn dependency:tree | grep postgresql`, or look for the
`postgresql-*.jar` in the application image. Very old drivers don't recognise `readOnlyMode`.
If Fix C has no effect with their version, upgrading pgJDBC is a dependency change, not a code change.

## See the leaked SETs on the database side

On the test PostgreSQL:

```sql
ALTER SYSTEM SET log_statement = 'all';
ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u app=%a ';
SELECT pg_reload_conf();
```

Run the baseline, then `grep -i "read only\|read write" /var/lib/pgsql/16/data/log/*.log`.
You'll see `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` and `... READ WRITE`
on different backend PIDs. Revert with `ALTER SYSTEM RESET log_statement; SELECT pg_reload_conf();`.

## All scenarios

```bash
./run.sh spring                             # Spring @Transactional(readOnly = true), baseline
FIX=track ./run.sh spring                   # Fix A
FIX=reset ./run.sh spring                   # Fix B
RO_MODE=transaction ./run.sh spring         # Fix C
./run.sh jdbc                               # plain JDBC setReadOnly(true) through HikariCP
./run.sh explicit                           # raw SET default_transaction_read_only = on/off
./run.sh none                               # control, expect 0 errors
./run-all.sh jdbc                           # summary for the plain JDBC path
```

Environment variables: `DB_PORT` (5432), `PGB_PORT` (6433), `MAVEN_REPO` (mirror for the plain
Java jars), `PGJDBC_VERSION` (Spring build only).

## Test against your own PgBouncer instead

Add `repro = host=<db> port=5432 dbname=repro` under `[databases]`, add `"repro" "repro"` to its
`auth_file`, set `ignore_startup_parameters = extra_float_digits`, then run:

```bash
./build-spring.sh
PGB_PORT=6432 RO_MODE=always java -jar spring-app/target/readonly-repro.jar --repro.seconds=30
```

## Production rollout notes

- After changing PgBouncer, run `RELOAD;` and then `RECONNECT;` (or restart) so that
  already-polluted server connections are dropped.
- With Fix B, `DISCARD ALL` must not be the reset query. It drops pgJDBC's prepared statements.
- Setting `ApplicationName=<service>` in each JDBC URL makes the source of such statements
  visible in the logs (`%a`) and in `pg_stat_activity`.

## Files

| File | Purpose |
|---|---|
| `install-centos.sh` | Installs PostgreSQL, PgBouncer and the JDK; creates the repro DB |
| `setup.sql` | Role, database and table (idempotent) |
| `pgbouncer.ini` | PgBouncer template (transaction pooling, `default_pool_size = 3`) |
| `userlist.txt` | PgBouncer auth file (`repro`/`repro`, lab only) |
| `spring-app/` | Spring Boot app: `ReportService` (`@Transactional(readOnly = true)`), `OrderService` (`@Transactional`), `LoadRunner` |
| `build-spring.sh` | Builds the Spring jar (downloads Maven if needed) |
| `Repro.java` | Plain HikariCP/JDBC variant (modes `jdbc`, `explicit`, `none`) |
| `run.sh` | One scenario |
| `run-all.sh` | Baseline plus all fixes, with a summary |
