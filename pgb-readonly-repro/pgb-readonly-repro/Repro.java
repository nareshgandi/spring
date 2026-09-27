import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import java.sql.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Reproduces read-only state leaking across clients through PgBouncer transaction pooling.
 *
 * Modes:
 *   explicit : readers run SET default_transaction_read_only = on ... off (matches the DB log)
 *   jdbc     : readers use conn.setReadOnly(true) with pgjdbc readOnlyMode=always
 *              (what Spring @Transactional(readOnly=true) + Hikari effectively does)
 *   none     : readers never touch read-only (control run, expect 0 errors)
 */
public class Repro {
    static final AtomicLong inserts = new AtomicLong();
    static final AtomicLong roErrors = new AtomicLong();
    static final AtomicLong otherErrors = new AtomicLong();
    static final AtomicLong reads = new AtomicLong();
    static volatile boolean running = true;

    public static void main(String[] args) throws Exception {
        String mode = args.length > 0 ? args[0] : "explicit";
        int seconds = args.length > 1 ? Integer.parseInt(args[1]) : 20;
        String port = System.getenv().getOrDefault("PGB_PORT", "6433");

        // prepareThreshold=0 avoids named prepared statements breaking under transaction pooling
        String url = "jdbc:postgresql://127.0.0.1:" + port + "/repro?prepareThreshold=0&ApplicationName=repro-" + mode;
        if (mode.equals("jdbc")) url += "&readOnlyMode=" + System.getenv().getOrDefault("RO_MODE", "always");

        HikariConfig cfg = new HikariConfig();
        cfg.setJdbcUrl(url);
        cfg.setUsername("repro");
        cfg.setPassword("repro");
        cfg.setMaximumPoolSize(10);
        cfg.setAutoCommit(true);
        cfg.setPoolName("repro-pool");
        HikariDataSource ds = new HikariDataSource(cfg);

        System.out.printf("mode=%s url=%s%n", mode, url);

        ExecutorService pool = Executors.newFixedThreadPool(6);
        for (int i = 0; i < 4; i++) pool.submit(() -> writer(ds));
        for (int i = 0; i < 2; i++) pool.submit(() -> reader(ds, mode));

        for (int s = 1; s <= seconds; s++) {
            Thread.sleep(1000);
            System.out.printf("t=%2ds inserts=%-6d readOnlyErrors=%-5d otherErrors=%-4d reads=%d%n",
                    s, inserts.get(), roErrors.get(), otherErrors.get(), reads.get());
        }
        running = false;
        pool.shutdown();
        pool.awaitTermination(10, TimeUnit.SECONDS);
        ds.close();

        System.out.println(roErrors.get() > 0
                ? "RESULT: REPRODUCED - " + roErrors.get() + " read-only errors leaked to writers"
                : "RESULT: no read-only errors");
    }

    static void writer(HikariDataSource ds) {
        while (running) {
            try (Connection c = ds.getConnection();
                 PreparedStatement ps = c.prepareStatement("INSERT INTO t(v) VALUES (?)")) {
                ps.setString(1, Thread.currentThread().getName());
                ps.executeUpdate();
                inserts.incrementAndGet();
            } catch (SQLException e) {
                record("writer", e);
            }
            sleep(5);
        }
    }

    static void reader(HikariDataSource ds, String mode) {
        while (running) {
            try (Connection c = ds.getConnection(); Statement st = c.createStatement()) {
                switch (mode) {
                    case "jdbc":
                        // pgjdbc sends SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY.
                        // Hikari resets it on close(), but under transaction pooling that
                        // READ WRITE reset can land on a different server backend.
                        c.setReadOnly(true);
                        st.executeQuery("SELECT 1 FROM t LIMIT 1").close();
                        break;
                    case "explicit":
                        // Each statement is its own transaction (autocommit), so PgBouncer
                        // may route these three statements to three different backends.
                        st.execute("SET default_transaction_read_only = on");
                        st.executeQuery("SELECT 1 FROM t LIMIT 1").close();
                        st.execute("SET default_transaction_read_only = off");
                        break;
                    default:
                        st.executeQuery("SELECT 1 FROM t LIMIT 1").close();
                }
                reads.incrementAndGet();
            } catch (SQLException e) {
                record("reader", e);
            }
            sleep(10);
        }
    }

    static void record(String who, SQLException e) {
        if ("25006".equals(e.getSQLState())) {          // read_only_sql_transaction
            if (roErrors.incrementAndGet() <= 3)
                System.out.println("  " + who + " ERROR: " + e.getMessage());
        } else if (otherErrors.incrementAndGet() <= 3) {
            System.out.println("  " + who + " OTHER [" + e.getSQLState() + "]: " + e.getMessage());
        }
    }

    static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
    }
}
