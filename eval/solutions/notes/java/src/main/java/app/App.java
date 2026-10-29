package app;

import com.fasterxml.jackson.annotation.JsonIgnore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;
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

    record User(int id, String username, byte[] salt, byte[] hash) {}

    record Credentials(String username, String password) {}

    record NewNote(String title, String text) {}

    record Note(int id, String title, String text, String createdAt, @JsonIgnore String owner) {}

    final Map<String, User> users = new HashMap<>();
    final Map<String, String> sessions = new HashMap<>();
    final Map<Integer, Note> notes = new LinkedHashMap<>();
    final SecureRandom random = new SecureRandom();
    int lastNote = 0;

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    static int length(String s) {
        return s.codePointCount(0, s.length());
    }

    static byte[] hash(String password, byte[] salt) throws Exception {
        var spec = new PBEKeySpec(password.toCharArray(), salt, 100_000, 256);
        return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).getEncoded();
    }

    synchronized String currentUser(String authorization) {
        if (authorization == null || !authorization.startsWith("Bearer "))
            return null;
        return sessions.get(authorization.substring("Bearer ".length()));
    }

    @PostMapping("/register")
    ResponseEntity<?> register(@RequestBody Credentials c) throws Exception {
        if (c.username() == null || length(c.username()) < 3 || length(c.username()) > 32
                || c.password() == null || length(c.password()) < 8)
            return ResponseEntity.badRequest().body("username must be 3-32 characters, password at least 8");
        var salt = new byte[16];
        random.nextBytes(salt);
        var hash = hash(c.password(), salt);
        synchronized (this) {
            if (users.containsKey(c.username()))
                return ResponseEntity.status(HttpStatus.CONFLICT).body("username is taken");
            var user = new User(users.size() + 1, c.username(), salt, hash);
            users.put(user.username(), user);
            return ResponseEntity.status(HttpStatus.CREATED).body(Map.of("id", user.id(), "username", user.username()));
        }
    }

    @PostMapping("/login")
    ResponseEntity<?> login(@RequestBody Credentials c) throws Exception {
        User user;
        synchronized (this) {
            user = users.get(c.username());
        }
        if (user == null || c.password() == null || !MessageDigest.isEqual(hash(c.password(), user.salt()), user.hash()))
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("invalid credentials");
        var bytes = new byte[24];
        random.nextBytes(bytes);
        var token = HexFormat.of().formatHex(bytes);
        synchronized (this) {
            sessions.put(token, user.username());
        }
        return ResponseEntity.ok(Map.of("token", token));
    }

    @PostMapping("/notes")
    ResponseEntity<?> create(@RequestBody NewNote n, @RequestHeader(name = "Authorization", required = false) String auth) {
        var user = currentUser(auth);
        if (user == null)
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("unauthorized");
        if (blank(n.title()))
            return ResponseEntity.badRequest().body("title is required");
        synchronized (this) {
            var note = new Note(++lastNote, n.title(), Objects.requireNonNullElse(n.text(), ""),
                    Instant.now().truncatedTo(ChronoUnit.SECONDS).toString(), user);
            notes.put(note.id(), note);
            return ResponseEntity.status(HttpStatus.CREATED).body(note);
        }
    }

    @GetMapping("/notes")
    ResponseEntity<?> list(@RequestHeader(name = "Authorization", required = false) String auth) {
        var user = currentUser(auth);
        if (user == null)
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("unauthorized");
        synchronized (this) {
            List<Note> own = notes.values().stream().filter(n -> n.owner().equals(user)).toList();
            return ResponseEntity.ok(own);
        }
    }

    @GetMapping("/notes/{id}")
    ResponseEntity<?> get(@PathVariable int id, @RequestHeader(name = "Authorization", required = false) String auth) {
        var user = currentUser(auth);
        if (user == null)
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("unauthorized");
        synchronized (this) {
            var note = notes.get(id);
            return note == null || !note.owner().equals(user) ? ResponseEntity.notFound().build() : ResponseEntity.ok(note);
        }
    }

    @DeleteMapping("/notes/{id}")
    ResponseEntity<?> delete(@PathVariable int id, @RequestHeader(name = "Authorization", required = false) String auth) {
        var user = currentUser(auth);
        if (user == null)
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("unauthorized");
        synchronized (this) {
            var note = notes.get(id);
            if (note == null || !note.owner().equals(user))
                return ResponseEntity.notFound().build();
            notes.remove(id);
            return ResponseEntity.noContent().build();
        }
    }
}
