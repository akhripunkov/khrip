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
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.stream.Collectors;
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

    static final String SCHEMA = """
            SELECT pg_advisory_xact_lock(hashtext('shop schema'));
            CREATE TABLE IF NOT EXISTS categories (
                id bigserial PRIMARY KEY,
                name text NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS categories_name_key ON categories (lower(name));
            CREATE TABLE IF NOT EXISTS products (
                id bigserial PRIMARY KEY,
                name text NOT NULL,
                category_id bigint NOT NULL REFERENCES categories,
                price bigint NOT NULL CHECK (price > 0),
                stock bigint NOT NULL CHECK (stock >= 0),
                tags text[] NOT NULL DEFAULT '{}'
            );
            CREATE TABLE IF NOT EXISTS orders (
                id bigserial PRIMARY KEY,
                customer text NOT NULL,
                status text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'cancelled')),
                total bigint NOT NULL,
                created_at timestamptz NOT NULL DEFAULT date_trunc('second', now())
            );
            CREATE INDEX IF NOT EXISTS orders_customer ON orders (customer, created_at);
            CREATE TABLE IF NOT EXISTS order_lines (
                order_id bigint NOT NULL REFERENCES orders,
                position int NOT NULL,
                product_id bigint NOT NULL REFERENCES products,
                qty bigint NOT NULL CHECK (qty > 0),
                price bigint NOT NULL,
                PRIMARY KEY (order_id, position)
            );
            """;
    static final Pattern TAG = Pattern.compile("[a-z0-9]{1,20}");

    record Category(long id, String name) {}

    record Product(long id, String name, long categoryId, long price, long stock, List<String> tags) {}

    record ProductInput(String name, Long categoryId, Long price, Long stock, List<String> tags) {}

    record ProductPage(List<Product> items, long total) {}

    record NewCategory(String name) {}

    record NewLine(long productId, long qty) {}

    record NewOrder(String customer, List<NewLine> lines) {}

    record Line(long productId, long qty, long price) {}

    record Order(long id, String customer, String status, long total, Instant createdAt, List<Line> lines) {}

    record CategoryStats(String category, long products, long unitsSold, long revenue) {}

    static final RowMapper<Category> CATEGORY = (rs, i) -> new Category(rs.getLong("id"), rs.getString("name"));
    static final RowMapper<Product> PRODUCT = (rs, i) -> new Product(rs.getLong("id"), rs.getString("name"),
            rs.getLong("category_id"), rs.getLong("price"), rs.getLong("stock"), List.of((String[]) rs.getArray("tags").getArray()));

    static Order order(ResultSet rs, int i) throws SQLException {
        return new Order(rs.getLong("id"), rs.getString("customer"), rs.getString("status"), rs.getLong("total"),
                rs.getObject("created_at", OffsetDateTime.class).toInstant(), List.of());
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

    static boolean valid(ProductInput p) {
        return (p.name() == null || !blank(p.name())) && (p.price() == null || p.price() > 0)
                && (p.stock() == null || p.stock() >= 0)
                && (p.tags() == null || p.tags().stream().distinct().count() <= 5
                        && p.tags().stream().allMatch(t -> t != null && TAG.matcher(t).matches()));
    }

    static String[] tags(List<String> tags) {
        return tags == null ? null : new LinkedHashSet<>(tags).toArray(String[]::new);
    }

    static boolean email(String s) {
        var parts = s == null ? new String[0] : s.split("@", -1);
        return parts.length == 2 && !parts[0].isEmpty() && !parts[1].isEmpty()
                && s.codePoints().noneMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    @PostMapping("/categories")
    ResponseEntity<?> category(@RequestBody NewCategory req) {
        var name = req.name() == null ? "" : req.name().strip();
        int length = name.codePointCount(0, name.length());
        if (length < 1 || length > 50)
            return ResponseEntity.badRequest().body("name must be 1-50 characters");
        var created = jdbc.query("INSERT INTO categories (name) VALUES (?) ON CONFLICT (lower(name)) DO NOTHING RETURNING *", CATEGORY, name);
        return created.isEmpty() ? ResponseEntity.status(HttpStatus.CONFLICT).body("category exists")
                : ResponseEntity.status(HttpStatus.CREATED).body(created.get(0));
    }

    @GetMapping("/categories")
    List<Category> categories() {
        return jdbc.query("SELECT * FROM categories ORDER BY name, id", CATEGORY);
    }

    @PostMapping("/products")
    ResponseEntity<?> create(@RequestBody ProductInput req) {
        if (req.name() == null || req.categoryId() == null || req.price() == null || req.stock() == null || !valid(req))
            return ResponseEntity.badRequest().body("name, category_id, price > 0 and stock >= 0 are required; up to 5 tags of 1-20 a-z or 0-9");
        var created = jdbc.query("""
                INSERT INTO products (name, category_id, price, stock, tags)
                SELECT ?, id, ?, ?, ? FROM categories WHERE id = ?
                RETURNING *
                """, PRODUCT, req.name(), req.price(), req.stock(), req.tags() == null ? new String[0] : tags(req.tags()), req.categoryId());
        return created.isEmpty() ? ResponseEntity.status(HttpStatus.NOT_FOUND).body("category not found")
                : ResponseEntity.status(HttpStatus.CREATED).body(created.get(0));
    }

    @GetMapping("/products/{id}")
    ResponseEntity<?> get(@PathVariable long id) {
        var found = jdbc.query("SELECT * FROM products WHERE id = ?", PRODUCT, id);
        return found.isEmpty() ? ResponseEntity.notFound().build() : ResponseEntity.ok(found.get(0));
    }

    @PatchMapping("/products/{id}")
    ResponseEntity<?> patch(@PathVariable long id, @RequestBody ProductInput req) {
        if (!valid(req))
            return ResponseEntity.badRequest().body("name must not be blank, price > 0, stock >= 0; up to 5 tags of 1-20 a-z or 0-9");
        var found = jdbc.query("""
                UPDATE products SET name = coalesce(?, name), price = coalesce(?, price),
                    stock = coalesce(?, stock), tags = coalesce(?, tags)
                WHERE id = ?
                RETURNING *
                """, PRODUCT, req.name(), req.price(), req.stock(), tags(req.tags()), id);
        return found.isEmpty() ? ResponseEntity.notFound().build() : ResponseEntity.ok(found.get(0));
    }

    @GetMapping("/products")
    ResponseEntity<?> list(@RequestParam(name = "category_id", required = false) Long categoryId,
            @RequestParam(required = false) String tag, @RequestParam(required = false) String q,
            @RequestParam(name = "min_price", required = false) Long minPrice,
            @RequestParam(name = "max_price", required = false) Long maxPrice,
            @RequestParam(name = "in_stock", required = false) Boolean inStock, @RequestParam(required = false) String sort,
            @RequestParam(defaultValue = "1") int page, @RequestParam(name = "per_page", defaultValue = "10") int perPage) {
        var orderBy = sort == null ? "id" : switch (sort) {
            case "price" -> "price, id";
            case "-price" -> "price DESC, id";
            case "name" -> "name, id";
            default -> null;
        };
        if (orderBy == null || page < 1 || perPage < 1 || perPage > 50)
            return ResponseEntity.badRequest().body("sort must be price, -price or name; page >= 1; per_page 1-50");
        var where = new StringBuilder("true");
        var params = new ArrayList<Object>();
        if (categoryId != null) {
            where.append(" AND category_id = ?");
            params.add(categoryId);
        }
        if (tag != null) {
            where.append(" AND ? = ANY(tags)");
            params.add(tag);
        }
        if (q != null) {
            where.append(" AND strpos(lower(name), lower(?)) > 0");
            params.add(q);
        }
        if (minPrice != null) {
            where.append(" AND price >= ?");
            params.add(minPrice);
        }
        if (maxPrice != null) {
            where.append(" AND price <= ?");
            params.add(maxPrice);
        }
        if (Boolean.TRUE.equals(inStock))
            where.append(" AND stock > 0");
        long total = jdbc.queryForObject("SELECT count(*) FROM products WHERE " + where, Long.class, params.toArray());
        params.add(perPage);
        params.add((page - 1L) * perPage);
        var items = jdbc.query("SELECT * FROM products WHERE " + where + " ORDER BY " + orderBy + " LIMIT ? OFFSET ?",
                PRODUCT, params.toArray());
        return ResponseEntity.ok(new ProductPage(items, total));
    }

    @PostMapping("/orders")
    ResponseEntity<?> order(@RequestBody NewOrder req) {
        var customer = req.customer() == null ? null : req.customer().toLowerCase(Locale.ROOT);
        if (!email(customer))
            return ResponseEntity.badRequest().body("customer must be an email");
        if (req.lines() == null || req.lines().isEmpty() || req.lines().stream().anyMatch(l -> l.qty() <= 0))
            return ResponseEntity.badRequest().body("lines must not be empty and qty must be positive");
        var wanted = new LinkedHashMap<Long, Long>();
        for (var l : req.lines())
            wanted.merge(l.productId(), l.qty(), Long::sum);
        return tx.execute(s -> {
            // Products are locked in id order, here and in cancel, so the two cannot deadlock.
            var prices = new LinkedHashMap<Long, Long>();
            var stock = new LinkedHashMap<Long, Long>();
            jdbc.query("SELECT id, price, stock FROM products WHERE id = ANY(?) ORDER BY id FOR UPDATE", rs -> {
                prices.put(rs.getLong("id"), rs.getLong("price"));
                stock.put(rs.getLong("id"), rs.getLong("stock"));
            }, (Object) wanted.keySet().toArray(Long[]::new));
            if (prices.size() < wanted.size())
                return ResponseEntity.status(HttpStatus.NOT_FOUND).body("unknown product");
            if (wanted.entrySet().stream().anyMatch(e -> stock.get(e.getKey()) < e.getValue()))
                return ResponseEntity.status(HttpStatus.CONFLICT).body("not enough stock");
            var lines = wanted.entrySet().stream().map(e -> new Line(e.getKey(), e.getValue(), prices.get(e.getKey()))).toList();
            var order = jdbc.queryForObject("INSERT INTO orders (customer, total) VALUES (?, ?) RETURNING *", App::order,
                    customer, lines.stream().mapToLong(l -> l.qty() * l.price()).sum());
            jdbc.batchUpdate("UPDATE products SET stock = stock - ? WHERE id = ?",
                    lines.stream().map(l -> new Object[] {l.qty(), l.productId()}).toList());
            var position = new int[1];
            jdbc.batchUpdate("INSERT INTO order_lines (order_id, position, product_id, qty, price) VALUES (?, ?, ?, ?, ?)",
                    lines.stream().map(l -> new Object[] {order.id(), position[0]++, l.productId(), l.qty(), l.price()}).toList());
            return ResponseEntity.status(HttpStatus.CREATED).body(withLines(List.of(order)).get(0));
        });
    }

    @PostMapping("/orders/{id}/cancel")
    ResponseEntity<?> cancel(@PathVariable long id) {
        return tx.execute(s -> {
            var found = jdbc.query("SELECT * FROM orders WHERE id = ? FOR UPDATE", App::order, id);
            if (found.isEmpty())
                return ResponseEntity.notFound().build();
            if (found.get(0).status().equals("cancelled"))
                return ResponseEntity.status(HttpStatus.CONFLICT).body("order is already cancelled");
            // Products are locked in id order, as in POST /orders, so the two cannot deadlock.
            jdbc.query("SELECT 1 FROM products WHERE id IN (SELECT product_id FROM order_lines WHERE order_id = ?) ORDER BY id FOR UPDATE",
                    rs -> {}, id);
            jdbc.update("UPDATE products p SET stock = p.stock + l.qty FROM order_lines l WHERE l.order_id = ? AND p.id = l.product_id", id);
            var order = jdbc.queryForObject("UPDATE orders SET status = 'cancelled' WHERE id = ? RETURNING *", App::order, id);
            return ResponseEntity.ok(withLines(List.of(order)).get(0));
        });
    }

    @GetMapping("/customers/{email}/orders")
    List<Order> customerOrders(@PathVariable String email) {
        return withLines(jdbc.query("SELECT * FROM orders WHERE customer = ? ORDER BY created_at DESC, id DESC", App::order,
                email.toLowerCase(Locale.ROOT)));
    }

    List<Order> withLines(List<Order> orders) {
        var ids = orders.stream().map(Order::id).toArray(Long[]::new);
        var lines = jdbc.query("SELECT order_id, product_id, qty, price FROM order_lines WHERE order_id = ANY(?) ORDER BY position",
                (rs, i) -> Map.entry(rs.getLong("order_id"), new Line(rs.getLong("product_id"), rs.getLong("qty"), rs.getLong("price"))),
                (Object) ids).stream().collect(Collectors.groupingBy(Map.Entry::getKey,
                        Collectors.mapping(Map.Entry::getValue, Collectors.toList())));
        return orders.stream().map(o -> new Order(o.id(), o.customer(), o.status(), o.total(), o.createdAt(),
                lines.getOrDefault(o.id(), List.of()))).toList();
    }

    @GetMapping("/stats/categories")
    List<CategoryStats> stats() {
        return jdbc.query("""
                SELECT c.name AS category, count(p.id) AS products,
                       coalesce(sum(s.units), 0)::bigint AS units_sold, coalesce(sum(s.revenue), 0)::bigint AS revenue
                FROM categories c
                LEFT JOIN products p ON p.category_id = c.id
                LEFT JOIN (
                    SELECT l.product_id, sum(l.qty) AS units, sum(l.qty * l.price) AS revenue
                    FROM order_lines l JOIN orders o ON o.id = l.order_id
                    WHERE o.status = 'placed'
                    GROUP BY l.product_id
                ) s ON s.product_id = p.id
                GROUP BY c.id
                ORDER BY revenue DESC, c.name
                """, (rs, i) -> new CategoryStats(rs.getString("category"), rs.getLong("products"), rs.getLong("units_sold"),
                rs.getLong("revenue")));
    }
}
