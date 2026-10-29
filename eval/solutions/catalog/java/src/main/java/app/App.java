package app;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.TreeMap;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@SpringBootApplication
@RestController
public class App {
    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    record Product(int id, String name, String category, double price, List<String> tags) {}

    record ProductInput(String name, String category, Double price, List<String> tags) {}

    record Page(List<Product> items, int total, int page, int perPage) {}

    record Category(String name, int count, double avgPrice) {}

    final List<Product> products = new ArrayList<>();

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    static boolean valid(Product p) {
        return !blank(p.name()) && !blank(p.category()) && p.price() >= 0;
    }

    @PostMapping("/products")
    ResponseEntity<?> create(@RequestBody ProductInput in) {
        var p = new Product(0, in.name(), in.category(), Objects.requireNonNullElse(in.price(), -1.0),
                Objects.requireNonNullElse(in.tags(), List.of()));
        if (!valid(p))
            return ResponseEntity.badRequest().body("name and category are required, price must not be negative");
        synchronized (this) {
            p = new Product(products.size() + 1, p.name(), p.category(), p.price(), p.tags());
            products.add(p);
        }
        return ResponseEntity.status(HttpStatus.CREATED).body(p);
    }

    @GetMapping("/products/{id}")
    synchronized ResponseEntity<?> get(@PathVariable int id) {
        return id >= 1 && id <= products.size() ? ResponseEntity.ok(products.get(id - 1)) : ResponseEntity.notFound().build();
    }

    @PatchMapping("/products/{id}")
    synchronized ResponseEntity<?> patch(@PathVariable int id, @RequestBody ProductInput in) {
        if (id < 1 || id > products.size())
            return ResponseEntity.notFound().build();
        var old = products.get(id - 1);
        var p = new Product(id, Objects.requireNonNullElse(in.name(), old.name()),
                Objects.requireNonNullElse(in.category(), old.category()),
                Objects.requireNonNullElse(in.price(), old.price()), Objects.requireNonNullElse(in.tags(), old.tags()));
        if (!valid(p))
            return ResponseEntity.badRequest().body("name and category are required, price must not be negative");
        products.set(id - 1, p);
        return ResponseEntity.ok(p);
    }

    @GetMapping("/products")
    ResponseEntity<?> list(@RequestParam(required = false) String q, @RequestParam(required = false) String category,
            @RequestParam(required = false) String tag, @RequestParam(name = "min_price", required = false) Double minPrice,
            @RequestParam(name = "max_price", required = false) Double maxPrice, @RequestParam(required = false) String sort,
            @RequestParam(defaultValue = "1") int page, @RequestParam(name = "per_page", defaultValue = "10") int perPage) {
        if (page < 1 || perPage < 1 || perPage > 100)
            return ResponseEntity.badRequest().body("page must be at least 1, per_page from 1 to 100");
        if (sort != null && !List.of("price", "-price", "name").contains(sort))
            return ResponseEntity.badRequest().body("sort must be price, -price or name");
        Comparator<Product> order = sort == null ? null : switch (sort) {
            case "price" -> Comparator.comparingDouble(Product::price);
            case "-price" -> Comparator.comparingDouble(Product::price).reversed();
            default -> Comparator.comparing(Product::name);
        };
        List<Product> all;
        synchronized (this) {
            all = List.copyOf(products);
        }
        var needle = q == null ? null : q.toLowerCase(Locale.ROOT);
        var stream = all.stream().filter(p -> (needle == null || p.name().toLowerCase(Locale.ROOT).contains(needle))
                && (category == null || p.category().equals(category))
                && (tag == null || p.tags().contains(tag))
                && (minPrice == null || p.price() >= minPrice)
                && (maxPrice == null || p.price() <= maxPrice));
        if (order != null)
            stream = stream.sorted(order);
        var items = stream.toList();
        int from = (int) Math.min(items.size(), (long) (page - 1) * perPage);
        return ResponseEntity.ok(new Page(items.subList(from, Math.min(items.size(), from + perPage)), items.size(), page, perPage));
    }

    @GetMapping("/categories")
    synchronized List<Category> categories() {
        var groups = new TreeMap<String, List<Product>>();
        for (var p : products)
            groups.computeIfAbsent(p.category(), k -> new ArrayList<>()).add(p);
        return groups.entrySet().stream().map(e -> {
            double avg = e.getValue().stream().mapToDouble(Product::price).average().orElse(0);
            return new Category(e.getKey(), e.getValue().size(), Math.round(avg * 100) / 100.0);
        }).toList();
    }
}
