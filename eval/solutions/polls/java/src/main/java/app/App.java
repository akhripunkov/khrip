package app;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
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

    record Option(String text, int votes) {}

    record Poll(int id, String question, List<Option> options, boolean closed) {}

    record NewPoll(String question, List<String> options) {}

    record Vote(int option) {}

    record Result(String text, int votes, double percent) {}

    final List<Poll> polls = new ArrayList<>();
    final List<Set<String>> voters = new ArrayList<>();

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    Poll find(int id) {
        return id >= 1 && id <= polls.size() ? polls.get(id - 1) : null;
    }

    @PostMapping("/polls")
    synchronized ResponseEntity<?> create(@RequestBody NewPoll req) {
        var options = req.options() == null ? List.<String>of() : req.options();
        if (blank(req.question()) || options.size() < 2 || options.size() > 10
                || options.stream().anyMatch(App::blank) || new HashSet<>(options).size() != options.size())
            return ResponseEntity.badRequest().body("question and 2-10 different options are required");
        var poll = new Poll(polls.size() + 1, req.question(), options.stream().map(o -> new Option(o, 0)).toList(), false);
        polls.add(poll);
        voters.add(new HashSet<>());
        return ResponseEntity.status(HttpStatus.CREATED).body(poll);
    }

    @GetMapping("/polls/{id}")
    synchronized ResponseEntity<?> get(@PathVariable int id) {
        var poll = find(id);
        return poll == null ? ResponseEntity.notFound().build() : ResponseEntity.ok(poll);
    }

    @GetMapping("/polls")
    synchronized List<Poll> list(@RequestParam(required = false) Boolean open) {
        return polls.stream().filter(p -> open == null || p.closed() != open).toList();
    }

    @PostMapping("/polls/{id}/votes")
    synchronized ResponseEntity<?> vote(@PathVariable int id, @RequestBody Vote req,
            @RequestHeader(name = "X-Voter-Id", required = false) String voter) {
        if (voter == null || voter.isEmpty())
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED).body("X-Voter-Id is required");
        var poll = find(id);
        if (poll == null)
            return ResponseEntity.notFound().build();
        if (poll.closed())
            return ResponseEntity.status(HttpStatus.FORBIDDEN).body("poll is closed");
        if (req.option() < 0 || req.option() >= poll.options().size())
            return ResponseEntity.badRequest().body("no such option");
        if (!voters.get(id - 1).add(voter))
            return ResponseEntity.status(HttpStatus.CONFLICT).body("already voted");
        var options = new ArrayList<>(poll.options());
        var o = options.get(req.option());
        options.set(req.option(), new Option(o.text(), o.votes() + 1));
        poll = new Poll(id, poll.question(), options, false);
        polls.set(id - 1, poll);
        return ResponseEntity.ok(poll);
    }

    @PostMapping("/polls/{id}/close")
    synchronized ResponseEntity<?> close(@PathVariable int id) {
        var poll = find(id);
        if (poll == null)
            return ResponseEntity.notFound().build();
        poll = new Poll(id, poll.question(), poll.options(), true);
        polls.set(id - 1, poll);
        return ResponseEntity.ok(poll);
    }

    @GetMapping("/polls/{id}/results")
    synchronized ResponseEntity<?> results(@PathVariable int id) {
        var poll = find(id);
        if (poll == null)
            return ResponseEntity.notFound().build();
        int total = poll.options().stream().mapToInt(Option::votes).sum();
        var results = poll.options().stream()
                .map(o -> new Result(o.text(), o.votes(), total == 0 ? 0 : Math.round(o.votes() * 1000.0 / total) / 10.0))
                .sorted(Comparator.comparingInt(Result::votes).reversed())
                .toList();
        return ResponseEntity.ok(Map.of("total", total, "results", results));
    }
}
