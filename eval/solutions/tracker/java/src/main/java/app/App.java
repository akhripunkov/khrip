package app;

import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import javax.sql.DataSource;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
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

    static final String SCHEMA = """
            SELECT pg_advisory_xact_lock(hashtext('tracker schema'));
            CREATE TABLE IF NOT EXISTS users (
                id bigserial PRIMARY KEY,
                email text NOT NULL UNIQUE,
                name text NOT NULL
            );
            CREATE TABLE IF NOT EXISTS projects (
                key text PRIMARY KEY,
                name text NOT NULL,
                owner_id bigint NOT NULL REFERENCES users,
                last_number int NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS issues (
                key text GENERATED ALWAYS AS (project || '-' || number) STORED UNIQUE,
                project text NOT NULL REFERENCES projects,
                number int NOT NULL,
                title text NOT NULL,
                status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'done')),
                priority text NOT NULL CHECK (priority IN ('low', 'medium', 'high')),
                assignee_id bigint REFERENCES users,
                created_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
                updated_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
                PRIMARY KEY (project, number)
            );
            """;
    static final Pattern KEY = Pattern.compile("[A-Z]{2,5}");
    static final Set<String> STATUSES = Set.of("open", "in_progress", "done");
    static final Set<String> PRIORITIES = Set.of("low", "medium", "high");

    record User(long id, String email, String name) {}

    record Project(String key, String name, long ownerId) {}

    record Issue(String key, String project, int number, String title, String status, String priority, Long assigneeId,
            Instant createdAt, Instant updatedAt) {}

    record NewUser(String email, String name) {}

    record NewProject(String key, String name, Long ownerId) {}

    record NewIssue(String title, String priority, Long assigneeId) {}

    record Assignee(long id, String name, long active) {}

    static Issue issue(ResultSet rs, int i) throws SQLException {
        return new Issue(rs.getString("key"), rs.getString("project"), rs.getInt("number"), rs.getString("title"),
                rs.getString("status"), rs.getString("priority"), rs.getObject("assignee_id", Long.class),
                rs.getObject("created_at", OffsetDateTime.class).toInstant(), rs.getObject("updated_at", OffsetDateTime.class).toInstant());
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

    static boolean validTitle(String title) {
        return !blank(title) && title.codePointCount(0, title.length()) <= 200;
    }

    static boolean email(String s) {
        var parts = s == null ? new String[0] : s.split("@", -1);
        return parts.length == 2 && !parts[0].isEmpty() && !parts[1].isEmpty()
                && s.codePoints().noneMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    @PostMapping("/users")
    ResponseEntity<?> user(@RequestBody NewUser req) {
        var email = req.email() == null ? null : req.email().toLowerCase(Locale.ROOT);
        if (!email(email) || blank(req.name()))
            return ResponseEntity.badRequest().body("email must be an address and name must not be blank");
        var created = jdbc.query("INSERT INTO users (email, name) VALUES (?, ?) ON CONFLICT (email) DO NOTHING RETURNING *",
                (rs, i) -> new User(rs.getLong("id"), rs.getString("email"), rs.getString("name")), email, req.name());
        return created.isEmpty() ? ResponseEntity.status(HttpStatus.CONFLICT).body("email exists")
                : ResponseEntity.status(HttpStatus.CREATED).body(created.get(0));
    }

    @PostMapping("/projects")
    ResponseEntity<?> project(@RequestBody NewProject req) {
        if (req.key() == null || !KEY.matcher(req.key()).matches() || blank(req.name()) || req.ownerId() == null)
            return ResponseEntity.badRequest().body("key must be 2-5 letters A-Z, name must not be blank, owner_id is required");
        try {
            jdbc.update("INSERT INTO projects (key, name, owner_id) VALUES (?, ?, ?)", req.key(), req.name(), req.ownerId());
            return ResponseEntity.status(HttpStatus.CREATED).body(new Project(req.key(), req.name(), req.ownerId()));
        } catch (DuplicateKeyException e) {
            return ResponseEntity.status(HttpStatus.CONFLICT).body("project exists");
        } catch (DataIntegrityViolationException e) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body("owner not found");
        }
    }

    // The project row lock taken by the counter update orders concurrent inserts, and a failed insert
    // rolls the counter back, so numbers are neither repeated nor skipped.
    @PostMapping("/projects/{key}/issues")
    ResponseEntity<?> create(@PathVariable String key, @RequestBody NewIssue req) {
        var priority = req.priority() == null ? "medium" : req.priority();
        if (!validTitle(req.title()) || !PRIORITIES.contains(priority))
            return ResponseEntity.badRequest().body("title must be 1-200 characters and not blank; priority low, medium or high");
        try {
            return tx.execute(s -> {
                var number = jdbc.queryForList("UPDATE projects SET last_number = last_number + 1 WHERE key = ? RETURNING last_number",
                        Integer.class, key);
                if (number.isEmpty())
                    return ResponseEntity.status(HttpStatus.NOT_FOUND).body("project not found");
                var issue = jdbc.queryForObject("""
                        INSERT INTO issues (project, number, title, priority, assignee_id)
                        VALUES (?, ?, ?, ?, ?)
                        RETURNING *
                        """, App::issue, key, number.get(0), req.title(), priority, req.assigneeId());
                return ResponseEntity.status(HttpStatus.CREATED).body(issue);
            });
        } catch (DataIntegrityViolationException e) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body("assignee not found");
        }
    }

    @GetMapping("/issues/{key}")
    ResponseEntity<?> get(@PathVariable String key) {
        var found = jdbc.query("SELECT * FROM issues WHERE key = ?", App::issue, key);
        return found.isEmpty() ? ResponseEntity.notFound().build() : ResponseEntity.ok(found.get(0));
    }

    // An absent field keeps its value; a given one must be valid, and "assignee_id": null removes the assignee.
    @PatchMapping("/issues/{key}")
    ResponseEntity<?> patch(@PathVariable String key, @RequestBody Map<String, Object> body) {
        var title = body.get("title");
        var status = body.get("status");
        var priority = body.get("priority");
        var assignee = body.get("assignee_id");
        if (body.containsKey("title") && !(title instanceof String t && validTitle(t))
                || body.containsKey("status") && !(status instanceof String st && STATUSES.contains(st))
                || body.containsKey("priority") && !(priority instanceof String p && PRIORITIES.contains(p))
                || assignee != null && !(assignee instanceof Integer || assignee instanceof Long))
            return ResponseEntity.badRequest().body("title must be 1-200 characters and not blank; status open, in_progress or done; priority low, medium or high; assignee_id a user id or null");
        try {
            var found = jdbc.query("""
                    UPDATE issues SET title = coalesce(?, title), status = coalesce(?, status),
                        priority = coalesce(?, priority),
                        assignee_id = CASE WHEN ? THEN ? ELSE assignee_id END,
                        updated_at = date_trunc('second', now())
                    WHERE key = ?
                    RETURNING *
                    """, App::issue, title, status, priority, body.containsKey("assignee_id"),
                    assignee == null ? null : ((Number) assignee).longValue(), key);
            return found.isEmpty() ? ResponseEntity.notFound().build() : ResponseEntity.ok(found.get(0));
        } catch (DataIntegrityViolationException e) {
            return ResponseEntity.status(HttpStatus.NOT_FOUND).body("assignee not found");
        }
    }

    @DeleteMapping("/issues/{key}")
    ResponseEntity<?> delete(@PathVariable String key) {
        return jdbc.update("DELETE FROM issues WHERE key = ?", key) == 0 ? ResponseEntity.notFound().build()
                : ResponseEntity.noContent().build();
    }

    @GetMapping("/projects/{key}/issues")
    ResponseEntity<?> list(@PathVariable String key, @RequestParam(required = false) String status,
            @RequestParam(name = "assignee_id", required = false) String assigneeId, @RequestParam(required = false) String q) {
        if (status != null && !STATUSES.contains(status) || assigneeId != null && !assigneeId.equals("none") && !assigneeId.matches("-?\\d{1,18}"))
            return ResponseEntity.badRequest().body("status must be open, in_progress or done; assignee_id a user id or none");
        var where = new StringBuilder("project = ?");
        var params = new ArrayList<Object>(List.of(key));
        if (status != null) {
            where.append(" AND status = ?");
            params.add(status);
        }
        if ("none".equals(assigneeId))
            where.append(" AND assignee_id IS NULL");
        else if (assigneeId != null) {
            where.append(" AND assignee_id = ?");
            params.add(Long.parseLong(assigneeId));
        }
        if (q != null) {
            where.append(" AND strpos(lower(title), lower(?)) > 0");
            params.add(q);
        }
        if (!jdbc.queryForObject("SELECT EXISTS (SELECT 1 FROM projects WHERE key = ?)", Boolean.class, key))
            return ResponseEntity.notFound().build();
        return ResponseEntity.ok(jdbc.query("SELECT * FROM issues WHERE " + where + " ORDER BY number", App::issue, params.toArray()));
    }

    @GetMapping("/projects/{key}/summary")
    ResponseEntity<?> summary(@PathVariable String key) {
        var counts = jdbc.queryForList("""
                SELECT count(i.number) AS total,
                       count(*) FILTER (WHERE i.status = 'open') AS open,
                       count(*) FILTER (WHERE i.status = 'in_progress') AS in_progress,
                       count(*) FILTER (WHERE i.status = 'done') AS done
                FROM projects p LEFT JOIN issues i ON i.project = p.key
                WHERE p.key = ?
                GROUP BY p.key
                """, key);
        if (counts.isEmpty())
            return ResponseEntity.notFound().build();
        var assignees = jdbc.query("""
                SELECT u.id, u.name, count(*) AS active
                FROM issues i JOIN users u ON u.id = i.assignee_id
                WHERE i.project = ? AND i.status <> 'done'
                GROUP BY u.id
                ORDER BY active DESC, u.id
                """, (rs, i) -> new Assignee(rs.getLong("id"), rs.getString("name"), rs.getLong("active")), key);
        var c = counts.get(0);
        return ResponseEntity.ok(Map.of("total", c.get("total"), "open", c.get("open"), "in_progress", c.get("in_progress"),
                "done", c.get("done"), "assignees", assignees));
    }
}
