package demo;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.CommandLineRunner;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

@Component
public class LoadRunner implements CommandLineRunner {

    private final ReportService reports;
    private final OrderService orders;
    private final DataSource dataSource;

    @Value("${repro.seconds}") private int seconds;
    @Value("${repro.writers}") private int writers;
    @Value("${repro.readers}") private int readers;
    @Value("${spring.datasource.url}") private String url;

    private final AtomicLong inserts = new AtomicLong();
    private final AtomicLong reads = new AtomicLong();
    private final AtomicLong roErrors = new AtomicLong();
    private final AtomicLong otherErrors = new AtomicLong();
    private volatile boolean running = true;

    public LoadRunner(ReportService reports, OrderService orders, DataSource dataSource) {
        this.reports = reports;
        this.orders = orders;
        this.dataSource = dataSource;
    }

    @Override
    public void run(String... args) throws Exception {
        try (Connection c = dataSource.getConnection()) {
            System.out.printf("spring-repro url=%s%n", url);
            System.out.printf("pgJDBC driver %s, %d writers (@Transactional), %d readers (@Transactional(readOnly = true))%n",
                    c.getMetaData().getDriverVersion(), writers, readers);
        }

        ExecutorService pool = Executors.newFixedThreadPool(writers + readers);
        for (int i = 0; i < writers; i++) {
            pool.submit(() -> {
                while (running) {
                    try {
                        orders.insertRow(Thread.currentThread().getName());
                        inserts.incrementAndGet();
                    } catch (RuntimeException e) {
                        record("writer", e);
                    }
                    sleep(5);
                }
            });
        }
        for (int i = 0; i < readers; i++) {
            pool.submit(() -> {
                while (running) {
                    try {
                        reports.countRows();
                        reads.incrementAndGet();
                    } catch (RuntimeException e) {
                        record("reader", e);
                    }
                    sleep(10);
                }
            });
        }

        for (int s = 1; s <= seconds; s++) {
            Thread.sleep(1000);
            System.out.printf("t=%2ds inserts=%-6d readOnlyErrors=%-5d otherErrors=%-4d reads=%d%n",
                    s, inserts.get(), roErrors.get(), otherErrors.get(), reads.get());
        }
        running = false;
        pool.shutdown();
        pool.awaitTermination(10, TimeUnit.SECONDS);

        System.out.println(roErrors.get() > 0
                ? "RESULT: REPRODUCED - " + roErrors.get() + " read-only errors leaked to writers"
                : "RESULT: no read-only errors");
    }

    private void record(String who, Throwable e) {
        SQLException sql = findSql(e);
        String state = sql == null ? null : sql.getSQLState();
        String msg = sql == null ? e.toString() : sql.getMessage();
        if ("25006".equals(state)) {             // read_only_sql_transaction
            if (roErrors.incrementAndGet() <= 3) System.out.println("  " + who + " ERROR: " + msg);
        } else if (otherErrors.incrementAndGet() <= 3) {
            System.out.println("  " + who + " OTHER [" + state + "]: " + msg);
        }
    }

    private static SQLException findSql(Throwable t) {
        while (t != null) {
            if (t instanceof SQLException s) return s;
            t = t.getCause();
        }
        return null;
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
    }
}
