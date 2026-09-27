# RCA: Intermittent "cannot execute INSERT in a read-only transaction" through PgBouncer

Sep 27, 2026 · @Naresh

## 1. Executive summary

Write transactions fail intermittently with SQLSTATE 25006 because read-only state set by one client leaks through a shared PgBouncer server connection into another client's write transaction. The leak happens when pgJDBC turns Spring's `@Transactional(readOnly = true)` into session-level `SET` statements. It also requires PgBouncer transaction pooling, which can route the "read only" SET and its "read write" reset to different PostgreSQL backends.

We reproduced the exact error in a lab on PgBouncer 1.25.2: 3,536 failed writes in 30 seconds, about 23% of all writes. All three candidate fixes brought failures to zero, and none needs an application code change.

| Item | Summary |
| --- | --- |
| Symptom | `ERROR: cannot execute INSERT in a read-only transaction` (SQLSTATE 25006) on write paths, intermittent |
| Root cause | Session-level `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` survives on a pooled backend after the client that set it moves on |
| Trigger conditions | PgBouncer transaction pooling, PgBouncer 1.25.x or older without tracking, pgJDBC sending session-level read-only SETs, concurrent readers and writers |
| Data impact | Failed writes are rejected and rolled back; no partial writes or corruption |
| Quick fix | `readOnlyMode=transaction` on the JDBC URL, or `track_extra_parameters = default_transaction_read_only` in PgBouncer |
| Long-term fix | Make read-only transaction-scoped in all services, upgrade PgBouncer to 1.26.0, and add monitoring for SQLSTATE 25006 |
| Status | Root cause confirmed in the lab; waiting for customer version details to confirm the match |

## 2. Problem statement

Application write transactions fail at random with the error below, even though the application is connected to a primary, read-write database.

```
ERROR: cannot execute INSERT in a read-only transaction
SQLSTATE: 25006 (read_only_sql_transaction)
```

What the customer observes:

- The failures are intermittent and not tied to one endpoint. Any `INSERT`, `UPDATE`, `DELETE` or DDL can be hit.
- The failing code path is a normal read-write `@Transactional` method. The code that *causes* the problem is a different, read-only method, which usually runs on another thread or request.
- A retry of the same write usually succeeds, so the problem looks random and is easy to write off as a glitch.
- Every client that shares the same PgBouncer pool (same database and user) is exposed, including services that never use read-only transactions.

What it is not:

- **Not a standby or replica.** 25006 is also the error you get when writing to a hot standby. `SELECT pg_is_in_recovery();` should return `false` on the affected server; confirm this to rule it out.
- **Not a permissions or ownership problem.** Those return a different SQLSTATE (42501).
- **Not a PostgreSQL bug.** PostgreSQL is correctly enforcing a read-only setting that really was set on that backend. The problem is *which client* set it.

## 3. Environment and exposure conditions

A system is exposed only when **all** of the conditions below are true. If any one is false, the leak cannot happen.

| Layer | Condition for exposure | Why it matters |
| --- | --- | --- |
| PgBouncer pooling | `pool_mode = transaction` (or `statement`) | The server connection is returned to the pool after every transaction, so consecutive statements from one client can run on different backends. `session` pooling is not affected. |
| PgBouncer version and config | 1.25.x or older, **and** `track_extra_parameters` does not include `default_transaction_read_only` | 1.26.0 tracks this parameter by default and restores each client's own value. Older versions restore only a small default set of parameters. |
| pgJDBC driver | Sends a session-level SET on `setReadOnly()` while autocommit is on (`readOnlyMode=always`, or older drivers that behave this way) | With `readOnlyMode=transaction` the driver sends `BEGIN READ ONLY` instead, and no session state is created. |
| Application framework | Spring `@Transactional(readOnly = true)` through HikariCP (or any code calling `Connection.setReadOnly(true)` outside a transaction) | Spring calls `setReadOnly(true)` *before* `setAutoCommit(false)`, and resets it *after* autocommit is back on. Both calls happen outside the transaction. |
| Workload | Readers and writers share one PgBouncer pool (same database and user), with concurrency | The race needs another client to grab the polluted backend before it is reset. |

Lab environment used for this analysis: EL9, PostgreSQL 16 (PGDG), PgBouncer 1.25.2 and 1.26.0 (PGDG), Java 17, Spring Boot 3.3.5, HikariCP, pgJDBC 42.7.4.

## 4. Root cause analysis

**Root cause:** Spring's read-only transaction handling makes pgJDBC send two session-level `SET` statements *outside* the transaction. In PgBouncer transaction pooling, each of these runs as its own mini-transaction and can go to a different PostgreSQL backend. The backend that receives the "read only" SET is never reset, stays read-only, and is later given to a writer.

### 4.1 What each layer sends

For one call to a `@Transactional(readOnly = true)` method, the sequence is:

| Step | Spring / HikariCP call | pgJDBC sends (`readOnlyMode=always` or older driver) | pgJDBC sends (`readOnlyMode=transaction`) |
| --- | --- | --- | --- |
| 1 | `setReadOnly(true)` while autocommit is still on | `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` as its own autocommit statement | nothing |
| 2 | `setAutoCommit(false)` | nothing | nothing |
| 3 | first query | `BEGIN` + query | `BEGIN READ ONLY` + query |
| 4 | commit | `COMMIT` | `COMMIT` |
| 5 | `setAutoCommit(true)`, then `setReadOnly(false)` | `SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE` as its own autocommit statement | nothing |

`SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` sets the backend's `default_transaction_read_only` to `on`. Every later transaction on that backend starts read-only until something sets it back, no matter which client is using it.

### 4.2 How PgBouncer routes it

&#91;embedded content: How the read-only state leaks · 5 steps across 2 clients and 2 backends\]

Steps 1, 3 and 5 of the table are three separate transactions from PgBouncer's point of view. PgBouncer releases the server connection after each one, so each can go to a different backend. Backend 1 keeps `default_transaction_read_only = on` until some client happens to send a "read write" SET to it, and any writer that gets it in the meantime fails.

### 4.3 Why PgBouncer does not clean it up

- **The reset query does not run.** In transaction pooling, `server_reset_query` (by default `DISCARD ALL`) is not run between clients unless `server_reset_query_always = 1`.
- **The parameter is not tracked before 1.26.0.** PgBouncer restores a client's own values only for the parameters it tracks: by default `client_encoding`, `datestyle`, `timezone`, `standard_conforming_strings` and `application_name` ([pgbouncer.ini manual](https://manpages.ubuntu.com/manpages/questing/man5/pgbouncer.5.html)). Other parameters can be added with `track_extra_parameters`.
- **1.26.0 changes this.** PgBouncer 1.26.0, released 2026-09-23, tracks `search_path` and `default_transaction_read_only` by default ([release announcement](https://www.postgresql.org/about/news/pgbouncer-1260-released-fixes-three-cves-3385/)). On 1.26.0 each client gets its own value restored, and the leak does not happen. We confirmed this in the lab (section 6).

Tracking needs PostgreSQL to report the parameter to the client. PostgreSQL 14 and later report `default_transaction_read_only`, which is why the tracking fix needs PostgreSQL 14+.

## 5. Why it is intermittent and hard to spot

The error needs a race to line up, it fixes itself, and it shows up in a different place from its cause. Those three facts explain why it looks random and why it hides in test environments.

- **It needs the SET and the reset to split.** If the "read only" SET and the "read write" reset go to the same backend, nothing leaks. PgBouncer reuses server connections last-in, first-out by default ([pgbouncer.ini manual](https://manpages.ubuntu.com/manpages/questing/man5/pgbouncer.5.html)), so under light load a client usually gets the same backend back. The split, and the error, mostly happen under production concurrency.
- **It heals itself.** Any later "read write" SET that happens to land on the polluted backend resets it. The window is often short, so a retry of the failed write usually succeeds.
- **The victim is not the culprit.** The failing request is a normal write. The request that caused it is a read-only report or query that finished successfully, often in another thread or service. Application logs point at the victim.
- **It depends on versions.** The same application behaves correctly on PgBouncer 1.26.0 or with `readOnlyMode=transaction`. An environment upgrade or a driver default can make the problem appear or disappear without any code change.

## 6. Reproduction and evidence

The error reproduced on PgBouncer 1.25.2, both in a forced single-connection test and through the real Spring code path under load. It did not reproduce on PgBouncer 1.26.0.

### 6.1 Lab setup

- **Stack:** EL9, PostgreSQL 16, PgBouncer 1.25.2 and 1.26.0 from PGDG, Java 17, Spring Boot 3.3.5, HikariCP, pgJDBC 42.7.4 with `readOnlyMode=always`.
- **PgBouncer:** `pool_mode = transaction`, `default_pool_size = 3` for the load test and `1` for the manual test, `server_reset_query = DISCARD ALL`, `server_reset_query_always = 0`.
- **Application:** 4 writer threads calling a `@Transactional` insert method, and 2 reader threads calling a `@Transactional(readOnly = true)` count method, all through one HikariCP pool.

### 6.2 Deterministic test (one server connection)

Client A runs `SET default_transaction_read_only = on` and disconnects. Client B then connects, runs `SHOW default_transaction_read_only` and tries an `INSERT`. With one server connection in the pool, client B always gets the backend client A used.

| PgBouncer | Fix applied | `SHOW` from client B | `INSERT` from client B |
| --- | --- | --- | --- |
| 1.26.0 | none | `off` | succeeds |
| 1.25.2 | none | `on` | fails, SQLSTATE 25006 |
| 1.25.2 | `track_extra_parameters = default_transaction_read_only` | `off` | succeeds |

### 6.3 Load test through Spring (PgBouncer 1.25.2, 3 server connections, 30 s per run)

| Scenario | Successful inserts | Read-only errors (25006) | Other errors |
| --- | --- | --- | --- |
| Baseline, no fix | 11,690 | **3,536** (about 23% of writes) | 0 |
| Fix A: `track_extra_parameters` | 15,011 | 0 | 0 |
| Fix B: `RESET` after every transaction | 15,018 | 0 | 0 |
| Fix C: `readOnlyMode=transaction` | 14,309 | 0 | 0 |

### 6.4 What the evidence shows

- The failure comes from the combination of Spring, HikariCP, pgJDBC and PgBouncer, not from application logic. The same code fails or succeeds based only on pooler and driver settings.
- Each fix removes the failure on its own, and none introduced other errors.
- On PgBouncer 1.26.0 the leak does not occur even in the forced single-connection test, because the parameter is tracked by default.
- The lab did not show a throughput difference between the fixes. Fix B's extra round trip per transaction may still matter at production volume.

## 7. Quick fix (immediate mitigation)

Apply **one** of the two configuration changes below, whichever layer the customer can change fastest. Both stop the leak without an application code change.

### Option 1: JDBC URL (application side)

Add `readOnlyMode=transaction` to the JDBC URL of every service that connects through PgBouncer:

```
jdbc:postgresql://<pgbouncer-host>:<port>/<db>?readOnlyMode=transaction&ApplicationName=<service-name>
```

1. Confirm the service's pgJDBC version supports `readOnlyMode` (see section 12). Very old drivers ignore it, and then this option has no effect.
2. Roll the change out with a normal rolling restart. Existing connections pick up the new URL only when they are recreated.
3. Verify that `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` no longer appears in the PostgreSQL log for that service (section 13).

### Option 2: PgBouncer (pooler side, versions 1.20 to 1.25)

Add this line to the `[pgbouncer]` section of `pgbouncer.ini`:

```
track_extra_parameters = default_transaction_read_only
```

If `track_extra_parameters` is already set (it defaults to `IntervalStyle` in some versions), add the new name to the existing comma-separated list rather than replacing it. Then, in the PgBouncer admin console:

```
RELOAD;
RECONNECT;
```

`RECONNECT` closes each server connection after it is released, which clears backends that are already polluted. If the new setting does not show in `SHOW CONFIG` after `RELOAD`, restart PgBouncer instead. This option needs PostgreSQL 14 or later.

### Stop-gap only: clear polluted connections

Running `RECONNECT;` alone clears the backends that are read-only right now. It is useful during an active incident, but the leak comes back as soon as read-only transactions run again. It is not a fix.

## 8. Long-term fix and hardening

The durable fix is to make sure read-only state never exists at the session level, and to keep the pooler protected as a second layer. Apply both, so that one misconfigured service or pooler cannot bring the problem back.

1. **Make read-only transaction-scoped everywhere (primary fix).** Set `readOnlyMode=transaction` explicitly in the shared base datasource configuration used by all services, instead of relying on driver defaults. The driver then sends `BEGIN READ ONLY`, which ends with the transaction.
2. **Upgrade PgBouncer to 1.26.0 (defense in depth).** It tracks `default_transaction_read_only` and `search_path` by default, and it also fixes three denial-of-service CVEs. 1.26.0 removes online restart (`-R`), so check that no restart scripts depend on it. On versions that cannot be upgraded soon, keep the `track_extra_parameters` setting from section 7.
3. **Keep pgJDBC current.** Standardize on a current 42.7.x release across services, so that `readOnlyMode` behaves the same everywhere and the fleet benefits from other driver fixes.
4. **Review session state under transaction pooling.** Transaction pooling assumes clients never leave session state behind. Audit services for other session-level features: `SET` without `LOCAL`, session advisory locks, temporary tables, `LISTEN` and session-level prepared statements.
5. **Add monitoring for SQLSTATE 25006.** Alert when any write fails with 25006 on a primary. On a correctly configured primary this count should always be zero.
6. **Make the source visible.** Set `ApplicationName=<service>` in every JDBC URL and include `%a` in `log_line_prefix`. This lets you trace any session-level SET to the service that sent it, in both the logs and `pg_stat_activity`.
7. **Add a regression test.** Run the reproduction bundle against staging before every PgBouncer or pgJDBC upgrade. It gives a clear pass or fail in a few minutes.

## 9. Fix options compared

Fix C is the recommended primary fix and Fix A is the recommended pooler-side safeguard. Fix B is a fallback for PgBouncer versions older than 1.20.

| Fix | Where | Change | Requirements | Readers stay read-only? | Runtime cost | Lab result |
| --- | --- | --- | --- | --- | --- | --- |
| **C** (recommended) | JDBC URL | `readOnlyMode=transaction` | pgJDBC that supports `readOnlyMode`; service restart | Yes, enforced per transaction with `BEGIN READ ONLY` | None | 0 errors |
| **A** (recommended safeguard) | PgBouncer | `track_extra_parameters = default_transaction_read_only`, or upgrade to 1.26.0 | PgBouncer 1.20+ and PostgreSQL 14+; `RELOAD` + `RECONNECT` | Yes, each client's own value is restored | None measurable | 0 errors |
| **B** (fallback) | PgBouncer | `server_reset_query = RESET default_transaction_read_only` + `server_reset_query_always = 1` | Any PgBouncer version | **No.** The reset wipes the setting after each transaction, so read-only is not enforced for readers | One extra round trip per transaction | 0 errors |

With Fix B, do not use `DISCARD ALL` as the reset query. Running it after every transaction also drops pgJDBC's prepared statements.

## 10. Rollout plan and verification

Confirm the diagnosis first, then roll out the fixes in staging and production. Success means zero 25006 errors on the primary.

### 10.1 Confirm the diagnosis (before any change)

1. Collect versions and settings (section 12): PgBouncer version, `pool_mode`, `track_extra_parameters`, pgJDBC version and the JDBC URL.
2. On the primary, confirm `SELECT pg_is_in_recovery();` returns `false`.
3. Temporarily set `log_statement = 'all'` on a non-production copy, or for a short window, and look for `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` from the application (section 13). Its presence confirms the driver is sending session-level SETs.

### 10.2 Staging

1. Point the reproduction bundle at the staging PgBouncer and run the baseline. It should report errors if staging matches production.
2. Apply Fix C to the services, and Fix A (or the 1.26.0 upgrade) to PgBouncer.
3. Rerun the bundle. The expected result is 0 read-only errors and 0 other errors.
4. Run the service's normal regression and performance tests.

### 10.3 Production

1. Apply the PgBouncer change first, followed by `RELOAD;` and `RECONNECT;`. This protects all clients at once, including services not yet updated.
2. Roll out `readOnlyMode=transaction` service by service with rolling restarts.
3. Watch the SQLSTATE 25006 count on the primary. It should drop to zero right after step 1 and stay there.
4. After all services are updated, confirm that the application no longer sends `SET SESSION CHARACTERISTICS` statements.

### 10.4 Rollback

- **PgBouncer:** remove the `track_extra_parameters` entry and run `RELOAD;`. For an upgrade, reinstall the previous package version.
- **Application:** remove `readOnlyMode=transaction` from the URL and restart.
- Neither change touches data or schema, so rollback is configuration only. If you roll back, the original risk comes back.

## 11. Postmortem

The investigation confirmed a configuration-level interaction between Spring, pgJDBC and PgBouncer, with no fault in application logic or PostgreSQL. The customer's incident timeline (first occurrence, detection, impact window) still needs to be filled in from their data (section 12).

### 11.1 Investigation timeline

| Date | Event |
| --- | --- |
| 2026-09-27 | Full Spring load test on 1.25.2: baseline 3,536 errors in 30 s; Fixes A, B and C all at 0 |
| 2026-09-27 | Fix A proven with the single-connection test on 1.25.2: client B sees `off`, insert succeeds |
| 2026-09-27 | PgBouncer downgraded to 1.25.2: single-connection test reproduces SQLSTATE 25006 |
| 2026-09-27 | Found that PgBouncer 1.26.0 (released 2026-09-23) tracks `default_transaction_read_only` by default |
| 2026-09-27 | Single-connection test on 1.26.0: no leak, which ruled out a load problem |
| 2026-09-27 | First lab run on PgBouncer 1.26.0: 0 errors in the baseline and in all fixes |
| 2026-09-25 | Reproduction bundle built: Spring, plain JDBC and raw SET modes, plus three fixes |

### 11.2 What went well

- A self-contained reproduction bundle let us test the real Spring code path, not just a simplified model.
- The single-connection test turned a timing-dependent race into a yes-or-no check, which isolated the PgBouncer version as the deciding factor.
- All three fixes were proven against the same baseline, with no side effects.

### 11.3 What was difficult

- The first lab runs used the newest PgBouncer, which already contains the fix, so the baseline could not fail. Low load was suspected at first, which cost time.
- The error shows up in the write path, while the cause is in the read path, so application logs point in the wrong direction.

### 11.4 Lessons learned

- **A failing baseline comes first.** A "no errors" result for a fix only counts if the baseline fails under the same conditions.
- **Pin and record versions.** Pooler and driver versions change behaviour here. Every test and every customer report should state them.
- **Session state and transaction pooling do not mix.** Any feature that sets session state is a candidate for the same class of leak.

### 11.5 Action items

- [ ] Collect the customer's versions and configuration (section 12) and confirm the match
- [ ] Apply the quick fix in the customer's staging environment and validate it with the bundle
- [ ] Roll out to production following section 10
- [ ] Add SQLSTATE 25006 alerting on primaries
- [ ] Plan the PgBouncer 1.26.0 upgrade
- [ ] Add a note to the bundle README that Fix A is automatic on PgBouncer 1.26.0 and later

## 12. Information needed from the customer

These details confirm that the customer's incident matches the reproduced root cause. The match is confirmed if PgBouncer is 1.25.x or older without tracking, runs transaction pooling, and the application sends session-level read-only SETs.

| Item | How to get it | What confirms the match |
| --- | --- | --- |
| PgBouncer version | `pgbouncer -V` | 1.25.x or older |
| Pool mode | `SHOW CONFIG;` in the admin console, or `pgbouncer.ini` | `transaction` or `statement` |
| Tracked parameters | `SHOW CONFIG;`, row `track_extra_parameters` | Does not include `default_transaction_read_only` |
| pgJDBC version | `mvn dependency:tree \| grep postgresql`, or the `postgresql-*.jar` in the application image | Needed to confirm Fix C will work |
| JDBC URL | Application configuration | No `readOnlyMode`, or `readOnlyMode=always` |
| Use of read-only transactions | Code search for `@Transactional(readOnly = true)` or `setReadOnly(true)` | Present in services sharing the pool |
| PostgreSQL version | `SELECT version();` | 14 or later needed for Fix A |
| Server role | `SELECT pg_is_in_recovery();` | `false` (primary) |
| PostgreSQL logs from an error window | `log_statement = 'all'` for a short window (section 13) | `SET SESSION CHARACTERISTICS ... READ ONLY` from the application |
| Incident timeline and impact | Application error metrics and logs | First occurrence, frequency, affected services and business impact, to complete section 11 |

## 13. Appendix

### A. Check whether a pooled backend is polluted

Run this repeatedly through PgBouncer while the application is under load. Any `on` means a backend is leaking read-only state:

```
for i in $(seq 30); do
  psql -X -h <pgbouncer-host> -p <port> -U <user> -d <db> -Atc \
    "select pg_backend_pid(), current_setting('default_transaction_read_only')"
done
```

### B. See the session-level SETs in PostgreSQL logs

```
ALTER SYSTEM SET log_statement = 'all';
ALTER SYSTEM SET log_line_prefix = '%m [%p] user=%u app=%a ';
SELECT pg_reload_conf();
-- reproduce or wait for the error, then:
--   grep -iE "read only|read write" $PGDATA/log/*.log
ALTER SYSTEM RESET log_statement;
ALTER SYSTEM RESET log_line_prefix;
SELECT pg_reload_conf();
```

The READ ONLY and READ WRITE `SET SESSION CHARACTERISTICS` statements from one application connection appear on different backend PIDs (`%p`). Use `log_statement = 'all'` only for a short window on a busy production system.

### C. Deterministic test (PgBouncer with `default_pool_size = 1`)

```
P="psql -X -h 127.0.0.1 -p 6433 -U repro -d repro"
$P -c "SET default_transaction_read_only = on"          # client A
$P -c "SHOW default_transaction_read_only" \
   -c "INSERT INTO t(v) VALUES ('manual')"               # client B
```

### D. Reproduction bundle (`pgb-readonly-repro`)

```
sudo ./install-centos.sh                  # EL8/EL9: PostgreSQL, PgBouncer, JDK 17
./run-all.sh spring 30                    # as a normal user: baseline + Fixes A, B, C
PGJDBC_VERSION=<customer version> FIX=none RO_MODE=always ./run.sh spring 30
```

On PgBouncer 1.26.0 or later the baseline does not fail, because Fix A is built in. Use 1.25.x or the customer's exact version to reproduce.

### E. Configuration snippets

```
# Fix A (pgbouncer.ini, [pgbouncer] section)
track_extra_parameters = default_transaction_read_only

# Fix B (pgbouncer.ini, fallback for PgBouncer < 1.20)
server_reset_query = RESET default_transaction_read_only
server_reset_query_always = 1

# Fix C (JDBC URL)
jdbc:postgresql://<host>:<port>/<db>?readOnlyMode=transaction&ApplicationName=<service>
```

### Sources

- [PgBouncer 1.26.0 release announcement](https://www.postgresql.org/about/news/pgbouncer-1260-released-fixes-three-cves-3385/), postgresql.org, 2026-09-23
- [pgbouncer.ini manual page](https://manpages.ubuntu.com/manpages/questing/man5/pgbouncer.5.html): `track_extra_parameters`, `server_round_robin`
- Lab reproduction logs, `results/` directory of the `pgb-readonly-repro` bundle, 2026-09-27
