package app;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.HashMap;
import java.util.Map;
import java.util.function.IntFunction;
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

    static final int LIMIT = 5;
    static final long WINDOW_MS = 1000L * Integer.parseInt(System.getenv().getOrDefault("WINDOW_SECONDS", "60"));

    record Window(long start, int used) {}

    final Map<String, Window> windows = new HashMap<>();

    Window active(String key, long now) {
        var w = windows.get(key);
        return w != null && now - w.start() < WINDOW_MS ? w : null;
    }

    static long secondsLeft(Window w, long now) {
        return (w.start() + WINDOW_MS - now + 999) / 1000;
    }

    // Counts a request of the key and answers with body(remaining), or with 401 or 429.
    synchronized ResponseEntity<?> limited(String key, IntFunction<Object> body) {
        if (key == null || key.isEmpty())
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("missing X-API-Key");
        long now = System.currentTimeMillis();
        var w = active(key, now);
        if (w == null)
            w = new Window(now, 0);
        if (w.used() >= LIMIT)
            return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
                    .header("Retry-After", String.valueOf(secondsLeft(w, now))).body("too many requests");
        w = new Window(w.start(), w.used() + 1);
        windows.put(key, w);
        return ResponseEntity.ok(body.apply(LIMIT - w.used()));
    }

    @GetMapping("/api/ping")
    ResponseEntity<?> ping(@RequestHeader(name = "X-API-Key", required = false) String key) {
        return limited(key, remaining -> Map.of("pong", true, "remaining", remaining));
    }

    @GetMapping("/api/time")
    ResponseEntity<?> time(@RequestHeader(name = "X-API-Key", required = false) String key) {
        return limited(key, remaining -> Map.of("time", Instant.now().truncatedTo(ChronoUnit.SECONDS).toString()));
    }

    @GetMapping("/limits/{key}")
    synchronized Map<String, Object> limits(@PathVariable String key) {
        long now = System.currentTimeMillis();
        var w = active(key, now);
        int used = w == null ? 0 : w.used();
        return Map.of("key", key, "used", used, "remaining", LIMIT - used, "reset_in", w == null ? 0 : secondsLeft(w, now));
    }
}
