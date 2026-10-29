package app;

import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import javax.sql.DataSource;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.bind.annotation.*;

@SpringBootApplication
@RestController
public class App {
    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    // DATABASE_URL is postgres://user:password@host:port/database?sslmode=disable
    @Bean
    static DataSource dataSource() {
        var url = URI.create(System.getenv("DATABASE_URL"));
        var user = url.getRawUserInfo().split(":", 2);
        var ds = new HikariDataSource();
        ds.setJdbcUrl("jdbc:postgresql://" + url.getHost() + ":" + url.getPort() + url.getRawPath()
                + (url.getRawQuery() == null ? "" : "?" + url.getRawQuery()));
        ds.setUsername(URLDecoder.decode(user[0], StandardCharsets.UTF_8));
        ds.setPassword(URLDecoder.decode(user[1], StandardCharsets.UTF_8));
        return ds;
    }

    // The statements run in one transaction, so the advisory lock keeps servers
    // starting at the same time from racing on the DDL.
    static final String SCHEMA = """
            SELECT pg_advisory_xact_lock(4207);
            CREATE TABLE IF NOT EXISTS accounts (
                id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                owner text NOT NULL,
                currency text NOT NULL,
                balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0)
            );
            CREATE TABLE IF NOT EXISTS transfers (
                id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                from_id bigint NOT NULL REFERENCES accounts,
                to_id bigint NOT NULL REFERENCES accounts,
                amount bigint NOT NULL CHECK (amount > 0),
                created_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
                idempotency_key text UNIQUE
            );
            CREATE INDEX IF NOT EXISTS transfers_from_id ON transfers (from_id, id);
            CREATE INDEX IF NOT EXISTS transfers_to_id ON transfers (to_id, id);
            """;
    static final String TRANSFER_COLUMNS = "id, from_id, to_id, amount, created_at";
    static final Set<String> CURRENCIES = Set.of("USD", "EUR", "GBP");

    record Account(long id, String owner, String currency, long balance) {}

    record Transfer(long id, long from, long to, long amount, Instant createdAt) {}

    record NewAccount(String owner, String currency) {}

    record Amount(long amount) {}

    record NewTransfer(long from, long to, long amount) {}

    static final RowMapper<Account> ACCOUNT = (rs, i) ->
            new Account(rs.getLong("id"), rs.getString("owner"), rs.getString("currency"), rs.getLong("balance"));

    static Transfer transfer(ResultSet rs, int i) throws SQLException {
        return new Transfer(rs.getLong("id"), rs.getLong("from_id"), rs.getLong("to_id"), rs.getLong("amount"),
                rs.getObject("created_at", OffsetDateTime.class).toInstant());
    }

    final JdbcTemplate jdbc;
    final TransactionTemplate tx;

    App(JdbcTemplate jdbc, TransactionTemplate tx) {
        this.jdbc = jdbc;
        this.tx = tx;
        tx.executeWithoutResult(s -> jdbc.execute(SCHEMA));
    }

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    static ResponseEntity<?> account(List<Account> found, HttpStatus status) {
        return found.isEmpty() ? ResponseEntity.status(HttpStatus.NOT_FOUND).body("account not found")
                : ResponseEntity.status(status).body(found.get(0));
    }

    @PostMapping("/accounts")
    ResponseEntity<?> open(@RequestBody NewAccount req) {
        if (blank(req.owner()) || req.currency() == null || !CURRENCIES.contains(req.currency()))
            return ResponseEntity.badRequest().body("owner is required; currency must be USD, EUR or GBP");
        return account(jdbc.query("INSERT INTO accounts (owner, currency) VALUES (?, ?) RETURNING *", ACCOUNT,
                req.owner(), req.currency()), HttpStatus.CREATED);
    }

    @GetMapping("/accounts/{id}")
    ResponseEntity<?> get(@PathVariable long id) {
        return account(jdbc.query("SELECT * FROM accounts WHERE id = ?", ACCOUNT, id), HttpStatus.OK);
    }

    @PostMapping("/accounts/{id}/deposit")
    ResponseEntity<?> deposit(@PathVariable long id, @RequestBody Amount req) {
        if (req.amount() <= 0)
            return ResponseEntity.badRequest().body("amount must be positive");
        return account(jdbc.query("UPDATE accounts SET balance = balance + ? WHERE id = ? RETURNING *", ACCOUNT,
                req.amount(), id), HttpStatus.OK);
    }

    // Same-key requests are serialized by an advisory lock on the key; the two
    // accounts are locked in id order, so crossing transfers cannot deadlock.
    @PostMapping("/transfers")
    ResponseEntity<?> transfer(@RequestBody NewTransfer req, @RequestHeader(name = "Idempotency-Key", required = false) String key) {
        if (req.amount() <= 0 || req.from() == req.to())
            return ResponseEntity.badRequest().body("amount must be positive and accounts different");
        if (key != null && (key.isEmpty() || key.codePointCount(0, key.length()) > 64))
            return ResponseEntity.badRequest().body("Idempotency-Key must be 1-64 characters");
        return tx.execute(s -> {
            if (key != null) {
                jdbc.queryForList("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", key);
                var done = jdbc.query("SELECT " + TRANSFER_COLUMNS + " FROM transfers WHERE idempotency_key = ?", App::transfer, key);
                if (!done.isEmpty()) {
                    var t = done.get(0);
                    if (t.from() != req.from() || t.to() != req.to() || t.amount() != req.amount())
                        return ResponseEntity.unprocessableEntity().body("Idempotency-Key was used with a different request");
                    return ResponseEntity.status(HttpStatus.CREATED).body(t);
                }
            }
            var locked = jdbc.query("SELECT * FROM accounts WHERE id IN (?, ?) ORDER BY id FOR UPDATE", ACCOUNT, req.from(), req.to());
            if (locked.size() < 2)
                return ResponseEntity.status(HttpStatus.NOT_FOUND).body("account not found");
            var from = locked.get(0).id() == req.from() ? locked.get(0) : locked.get(1);
            var to = locked.get(0).id() == req.from() ? locked.get(1) : locked.get(0);
            if (!from.currency().equals(to.currency()))
                return ResponseEntity.unprocessableEntity().body("accounts have different currencies");
            if (from.balance() < req.amount())
                return ResponseEntity.status(HttpStatus.CONFLICT).body("insufficient funds");
            jdbc.update("UPDATE accounts SET balance = balance - ? WHERE id = ?", req.amount(), req.from());
            jdbc.update("UPDATE accounts SET balance = balance + ? WHERE id = ?", req.amount(), req.to());
            var t = jdbc.queryForObject("INSERT INTO transfers (from_id, to_id, amount, idempotency_key) VALUES (?, ?, ?, ?) RETURNING "
                    + TRANSFER_COLUMNS, App::transfer, req.from(), req.to(), req.amount(), key);
            return ResponseEntity.status(HttpStatus.CREATED).body(t);
        });
    }

    @GetMapping("/accounts/{id}/transfers")
    ResponseEntity<?> history(@PathVariable long id, @RequestParam(defaultValue = "20") int limit,
            @RequestParam(defaultValue = "" + Long.MAX_VALUE) long before) {
        if (limit < 1 || limit > 100)
            return ResponseEntity.badRequest().body("limit must be 1-100");
        if (!jdbc.queryForObject("SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ?)", Boolean.class, id))
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body("account not found");
        return ResponseEntity.ok(jdbc.query("SELECT " + TRANSFER_COLUMNS
                + " FROM transfers WHERE (from_id = ? OR to_id = ?) AND id < ? ORDER BY id DESC LIMIT ?",
                App::transfer, id, id, before, limit));
    }

    @GetMapping("/stats")
    Map<String, Object> stats() {
        return jdbc.queryForObject("""
                SELECT count(*), (SELECT count(*) FROM transfers),
                    coalesce(sum(balance) FILTER (WHERE currency = 'USD'), 0)::bigint,
                    coalesce(sum(balance) FILTER (WHERE currency = 'EUR'), 0)::bigint,
                    coalesce(sum(balance) FILTER (WHERE currency = 'GBP'), 0)::bigint
                FROM accounts
                """, (rs, i) -> {
            var balances = new LinkedHashMap<String, Long>();
            balances.put("USD", rs.getLong(3));
            balances.put("EUR", rs.getLong(4));
            balances.put("GBP", rs.getLong(5));
            return Map.of("accounts", rs.getLong(1), "transfers", rs.getLong(2), "balances", balances);
        });
    }
}
