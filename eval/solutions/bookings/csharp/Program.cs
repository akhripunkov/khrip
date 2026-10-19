using System.Globalization;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();
var rooms = new List<Room>();
var bookings = new Dictionary<int, Booking>();
var gate = new object();
var lastBooking = 0;

DateTime? ParseTime(string? s, string format) =>
    DateTime.TryParseExact(s, format, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var t) ? t : null;

app.MapPost("/rooms", (NewRoom req) =>
{
    if (string.IsNullOrWhiteSpace(req.Name) || req.Capacity < 1)
        return Results.BadRequest("name is required and capacity must be at least 1");
    lock (gate)
    {
        var room = new Room(rooms.Count + 1, req.Name, req.Capacity);
        rooms.Add(room);
        return Results.Created($"/rooms/{room.Id}", room);
    }
});

app.MapPost("/bookings", (NewBooking req) =>
{
    var start = ParseTime(req.Start, "yyyy-MM-ddTHH:mm:ssZ");
    var end = ParseTime(req.End, "yyyy-MM-ddTHH:mm:ssZ");
    if (start is null || end is null || end <= start || end - start > TimeSpan.FromHours(8) || string.IsNullOrWhiteSpace(req.Title))
        return Results.BadRequest("need a title and valid start < end, at most 8 hours apart");
    lock (gate)
    {
        if (req.RoomId < 1 || req.RoomId > rooms.Count)
            return Results.NotFound();
        if (bookings.Values.Any(b => b.RoomId == req.RoomId && b.From < end && start < b.To))
            return Results.Conflict("the room is booked at that time");
        var booking = new Booking(++lastBooking, req.RoomId, req.Title, req.Start!, req.End!) { From = start.Value, To = end.Value };
        bookings[booking.Id] = booking;
        return Results.Created($"/bookings/{booking.Id}", booking);
    }
});

app.MapGet("/rooms/{id:int}/bookings", (int id, string? date) =>
{
    var from = DateTime.MinValue;
    var to = DateTime.MaxValue;
    if (date is not null)
    {
        var day = ParseTime(date, "yyyy-MM-dd");
        if (day is null)
            return Results.BadRequest("date must look like 2026-10-19");
        from = day.Value;
        to = from.AddDays(1);
    }
    lock (gate)
    {
        if (id < 1 || id > rooms.Count)
            return Results.NotFound();
        return Results.Ok(bookings.Values.Where(b => b.RoomId == id && b.From < to && from < b.To).OrderBy(b => b.From).ToList());
    }
});

app.MapDelete("/bookings/{id:int}", (int id) =>
{
    lock (gate)
        return bookings.Remove(id) ? Results.NoContent() : Results.NotFound();
});

app.Run();

record NewRoom(string? Name, int Capacity);
record Room(int Id, string Name, int Capacity);
record NewBooking(int RoomId, string? Title, string? Start, string? End);

record Booking(int Id, int RoomId, string Title, string Start, string End)
{
    [System.Text.Json.Serialization.JsonIgnore] public DateTime From { get; init; }
    [System.Text.Json.Serialization.JsonIgnore] public DateTime To { get; init; }
}
