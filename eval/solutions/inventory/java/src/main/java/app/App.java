package app;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.regex.Pattern;
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

    record Item(String sku, String name, long stock) {}

    record Line(String sku, long qty) {}

    record Order(int id, List<Line> lines, String status, long totalQty) {}

    record Restock(long amount) {}

    record NewOrder(List<Line> lines) {}

    static final Pattern SKU = Pattern.compile("[A-Z0-9-]{3,20}");
    final Map<String, Item> items = new TreeMap<>();
    final List<Order> orders = new ArrayList<>();

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    @PostMapping("/items")
    synchronized ResponseEntity<?> add(@RequestBody Item item) {
        if (item.sku() == null || !SKU.matcher(item.sku()).matches() || blank(item.name()) || item.stock() < 0)
            return ResponseEntity.badRequest().body("sku must be 3-20 of A-Z, 0-9, -; name required; stock >= 0");
        if (items.putIfAbsent(item.sku(), item) != null)
            return ResponseEntity.status(HttpStatus.CONFLICT).body("sku exists");
        return ResponseEntity.status(HttpStatus.CREATED).body(item);
    }

    @GetMapping("/items")
    synchronized List<Item> list() {
        return List.copyOf(items.values());
    }

    @PostMapping("/items/{sku}/restock")
    synchronized ResponseEntity<?> restock(@PathVariable String sku, @RequestBody Restock req) {
        var item = items.get(sku);
        if (item == null)
            return ResponseEntity.notFound().build();
        if (req.amount() <= 0)
            return ResponseEntity.badRequest().body("amount must be positive");
        item = new Item(sku, item.name(), item.stock() + req.amount());
        items.put(sku, item);
        return ResponseEntity.ok(item);
    }

    @PostMapping("/orders")
    synchronized ResponseEntity<?> order(@RequestBody NewOrder req) {
        if (req.lines() == null || req.lines().isEmpty() || req.lines().stream().anyMatch(l -> l.sku() == null || l.qty() <= 0))
            return ResponseEntity.badRequest().body("lines must not be empty and qty must be positive");
        var need = new LinkedHashMap<String, Long>();
        for (var l : req.lines())
            need.merge(l.sku(), l.qty(), Long::sum);
        for (var e : need.entrySet()) {
            var item = items.get(e.getKey());
            if (item == null)
                return ResponseEntity.status(HttpStatus.NOT_FOUND).body("unknown sku " + e.getKey());
            if (item.stock() < e.getValue())
                return ResponseEntity.status(HttpStatus.CONFLICT).body("not enough " + e.getKey());
        }
        need.forEach((sku, qty) -> items.computeIfPresent(sku, (k, i) -> new Item(k, i.name(), i.stock() - qty)));
        var order = new Order(orders.size() + 1, req.lines(), "placed", req.lines().stream().mapToLong(Line::qty).sum());
        orders.add(order);
        return ResponseEntity.status(HttpStatus.CREATED).body(order);
    }

    @PostMapping("/orders/{id}/cancel")
    synchronized ResponseEntity<?> cancel(@PathVariable int id) {
        if (id < 1 || id > orders.size())
            return ResponseEntity.notFound().build();
        var order = orders.get(id - 1);
        if (order.status().equals("cancelled"))
            return ResponseEntity.status(HttpStatus.CONFLICT).body("already cancelled");
        for (var l : order.lines())
            items.computeIfPresent(l.sku(), (k, i) -> new Item(k, i.name(), i.stock() + l.qty()));
        order = new Order(id, order.lines(), "cancelled", order.totalQty());
        orders.set(id - 1, order);
        return ResponseEntity.ok(order);
    }

    @GetMapping("/orders")
    synchronized ResponseEntity<?> orders(@RequestParam(required = false) String status) {
        if (status != null && !status.equals("placed") && !status.equals("cancelled"))
            return ResponseEntity.badRequest().body("status must be placed or cancelled");
        return ResponseEntity.ok(orders.stream().filter(o -> status == null || o.status().equals(status)).toList());
    }
}
