package app;

import com.fasterxml.jackson.annotation.JsonIgnore;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeParseException;
import java.time.format.ResolverStyle;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
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

    record Room(int id, String name, int capacity) {}

    record Booking(int id, int roomId, String title, String start, String end, @JsonIgnore Instant from, @JsonIgnore Instant to) {}

    record NewRoom(String name, int capacity) {}

    record NewBooking(int roomId, String title, String start, String end) {}

    static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss'Z'").withResolverStyle(ResolverStyle.STRICT);
    static final DateTimeFormatter DATE = DateTimeFormatter.ofPattern("uuuu-MM-dd").withResolverStyle(ResolverStyle.STRICT);
    final List<Room> rooms = new ArrayList<>();
    final Map<Integer, Booking> bookings = new LinkedHashMap<>();
    int lastBooking = 0;

    static boolean blank(String s) {
        return s == null || s.codePoints().allMatch(c -> Character.isWhitespace(c) || Character.isSpaceChar(c));
    }

    static Instant parseTime(String s) {
        try {
            return LocalDateTime.parse(s, TIME).toInstant(ZoneOffset.UTC);
        } catch (DateTimeParseException | NullPointerException e) {
            return null;
        }
    }

    @PostMapping("/rooms")
    synchronized ResponseEntity<?> room(@RequestBody NewRoom req) {
        if (blank(req.name()) || req.capacity() < 1)
            return ResponseEntity.badRequest().body("name is required and capacity must be at least 1");
        var room = new Room(rooms.size() + 1, req.name(), req.capacity());
        rooms.add(room);
        return ResponseEntity.status(HttpStatus.CREATED).body(room);
    }

    @PostMapping("/bookings")
    synchronized ResponseEntity<?> book(@RequestBody NewBooking req) {
        var start = parseTime(req.start());
        var end = parseTime(req.end());
        if (start == null || end == null || !end.isAfter(start)
                || Duration.between(start, end).compareTo(Duration.ofHours(8)) > 0 || blank(req.title()))
            return ResponseEntity.badRequest().body("need a title and valid start < end, at most 8 hours apart");
        if (req.roomId() < 1 || req.roomId() > rooms.size())
            return ResponseEntity.notFound().build();
        if (bookings.values().stream().anyMatch(b -> b.roomId() == req.roomId() && b.from().isBefore(end) && start.isBefore(b.to())))
            return ResponseEntity.status(HttpStatus.CONFLICT).body("the room is booked at that time");
        var booking = new Booking(++lastBooking, req.roomId(), req.title(), req.start(), req.end(), start, end);
        bookings.put(booking.id(), booking);
        return ResponseEntity.status(HttpStatus.CREATED).body(booking);
    }

    @GetMapping("/rooms/{id}/bookings")
    synchronized ResponseEntity<?> list(@PathVariable int id, @RequestParam(required = false) String date) {
        Instant from = Instant.MIN, to = Instant.MAX;
        if (date != null) {
            try {
                from = LocalDate.parse(date, DATE).atStartOfDay(ZoneOffset.UTC).toInstant();
            } catch (DateTimeParseException e) {
                return ResponseEntity.badRequest().body("date must look like 2026-10-19");
            }
            to = from.plus(Duration.ofDays(1));
        }
        if (id < 1 || id > rooms.size())
            return ResponseEntity.notFound().build();
        Instant dayFrom = from, dayTo = to;
        return ResponseEntity.ok(bookings.values().stream()
                .filter(b -> b.roomId() == id && b.from().isBefore(dayTo) && dayFrom.isBefore(b.to()))
                .sorted(Comparator.comparing(Booking::from))
                .toList());
    }

    @DeleteMapping("/bookings/{id}")
    synchronized ResponseEntity<?> delete(@PathVariable int id) {
        return bookings.remove(id) == null ? ResponseEntity.notFound().build() : ResponseEntity.noContent().build();
    }
}
