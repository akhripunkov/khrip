package app;

import java.security.SecureRandom;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@SpringBootApplication
@RestController
public class App {
    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    record Link(String code, String url, int clicks) {}

    record NewLink(String url, String code) {}

    static final String ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    static final Pattern CODE = Pattern.compile("[A-Za-z0-9_-]{3,32}");
    final Map<String, Link> links = new ConcurrentHashMap<>();
    final SecureRandom random = new SecureRandom();

    String randomCode() {
        var sb = new StringBuilder(7);
        for (int i = 0; i < 7; i++)
            sb.append(ALPHABET.charAt(random.nextInt(ALPHABET.length())));
        return sb.toString();
    }

    @PostMapping("/links")
    ResponseEntity<?> create(@RequestBody NewLink req) {
        if (req.url() == null || !(req.url().startsWith("http://") || req.url().startsWith("https://")))
            return ResponseEntity.badRequest().body("url must start with http:// or https://");
        if (req.code() != null && !CODE.matcher(req.code()).matches())
            return ResponseEntity.badRequest().body("code must be 3-32 letters, digits, - or _");
        if (req.code() != null) {
            var link = new Link(req.code(), req.url(), 0);
            if (links.putIfAbsent(link.code(), link) != null)
                return ResponseEntity.status(HttpStatus.CONFLICT).body("code is taken");
            return ResponseEntity.status(HttpStatus.CREATED).body(link);
        }
        while (true) {
            var link = new Link(randomCode(), req.url(), 0);
            if (links.putIfAbsent(link.code(), link) == null)
                return ResponseEntity.status(HttpStatus.CREATED).body(link);
        }
    }

    @GetMapping("/{code}")
    ResponseEntity<?> redirect(@PathVariable String code) {
        var link = links.computeIfPresent(code, (k, l) -> new Link(l.code(), l.url(), l.clicks() + 1));
        if (link == null)
            return ResponseEntity.notFound().build();
        return ResponseEntity.status(HttpStatus.FOUND).header(HttpHeaders.LOCATION, link.url()).build();
    }

    @GetMapping("/links")
    List<Link> list() {
        return links.values().stream()
                .sorted(Comparator.comparingInt(Link::clicks).reversed().thenComparing(Link::code))
                .toList();
    }

    @GetMapping("/links/{code}")
    ResponseEntity<?> get(@PathVariable String code) {
        var link = links.get(code);
        return link == null ? ResponseEntity.notFound().build() : ResponseEntity.ok(link);
    }

    @DeleteMapping("/links/{code}")
    ResponseEntity<?> delete(@PathVariable String code) {
        return links.remove(code) == null ? ResponseEntity.notFound().build() : ResponseEntity.noContent().build();
    }
}
