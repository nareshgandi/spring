package demo;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * The customer's read path. Spring's transaction manager calls
 * connection.setReadOnly(true) BEFORE setAutoCommit(false), and
 * setReadOnly(false) AFTER setAutoCommit(true) on cleanup.
 * With pgJDBC readOnlyMode=always those two calls become separate
 * session-level SETs, which PgBouncer may route to different backends.
 */
@Service
public class ReportService {
    private final JdbcTemplate jdbc;

    public ReportService(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Transactional(readOnly = true)
    public long countRows() {
        Long n = jdbc.queryForObject("SELECT count(*) FROM t", Long.class);
        return n == null ? 0 : n;
    }
}
