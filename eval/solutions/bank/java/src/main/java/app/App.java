package app;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
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

    record Account(int id, String owner, long balance) {}

    record Transfer(int id, int fromId, int toId, long amount, String createdAt) {}

    record NewAccount(String owner) {}

    record Amount(long amount) {}

    record NewTransfer(int fromId, int toId, long amount) {}

    final Map<Integer, Account> accounts = new HashMap<>();
    final List<Transfer> transfers = new ArrayList<>();

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    @PostMapping("/accounts")
    synchronized ResponseEntity<?> open(@RequestBody NewAccount req) {
        if (blank(req.owner()))
            return ResponseEntity.badRequest().body("owner is required");
        var account = new Account(accounts.size() + 1, req.owner(), 0);
        accounts.put(account.id(), account);
        return ResponseEntity.status(HttpStatus.CREATED).body(account);
    }

    @GetMapping("/accounts/{id}")
    synchronized ResponseEntity<?> get(@PathVariable int id) {
        var account = accounts.get(id);
        return account == null ? ResponseEntity.notFound().build() : ResponseEntity.ok(account);
    }

    @PostMapping("/accounts/{id}/deposit")
    synchronized ResponseEntity<?> deposit(@PathVariable int id, @RequestBody Amount req) {
        var account = accounts.get(id);
        if (account == null)
            return ResponseEntity.notFound().build();
        if (req.amount() <= 0)
            return ResponseEntity.badRequest().body("amount must be positive");
        account = new Account(id, account.owner(), account.balance() + req.amount());
        accounts.put(id, account);
        return ResponseEntity.ok(account);
    }

    @PostMapping("/transfers")
    synchronized ResponseEntity<?> transfer(@RequestBody NewTransfer req) {
        if (req.amount() <= 0 || req.fromId() == req.toId())
            return ResponseEntity.badRequest().body("amount must be positive and accounts different");
        var from = accounts.get(req.fromId());
        var to = accounts.get(req.toId());
        if (from == null || to == null)
            return ResponseEntity.notFound().build();
        if (from.balance() < req.amount())
            return ResponseEntity.status(HttpStatus.CONFLICT).body("insufficient funds");
        accounts.put(from.id(), new Account(from.id(), from.owner(), from.balance() - req.amount()));
        accounts.put(to.id(), new Account(to.id(), to.owner(), to.balance() + req.amount()));
        var t = new Transfer(transfers.size() + 1, req.fromId(), req.toId(), req.amount(),
                Instant.now().truncatedTo(ChronoUnit.SECONDS).toString());
        transfers.add(t);
        return ResponseEntity.status(HttpStatus.CREATED).body(t);
    }

    @GetMapping("/accounts/{id}/transfers")
    synchronized ResponseEntity<?> history(@PathVariable int id) {
        if (!accounts.containsKey(id))
            return ResponseEntity.notFound().build();
        return ResponseEntity.ok(transfers.reversed().stream().filter(t -> t.fromId() == id || t.toId() == id).toList());
    }
}
