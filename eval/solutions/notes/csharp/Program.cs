using System.Security.Cryptography;
using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();
var users = new Dictionary<string, User>();
var sessions = new Dictionary<string, string>();
var notes = new Dictionary<int, Note>();
var gate = new object();
var lastNote = 0;

string? CurrentUser(HttpRequest req)
{
    var header = req.Headers.Authorization.ToString();
    if (!header.StartsWith("Bearer "))
        return null;
    lock (gate)
        return sessions.GetValueOrDefault(header["Bearer ".Length..]);
}

app.MapPost("/register", (Credentials c) =>
{
    if (c.Username is null || c.Username.Length < 3 || c.Username.Length > 32 || c.Password is null || c.Password.Length < 8)
        return Results.BadRequest("username must be 3-32 characters, password at least 8");
    var salt = RandomNumberGenerator.GetBytes(16);
    var hash = Rfc2898DeriveBytes.Pbkdf2(c.Password, salt, 100_000, HashAlgorithmName.SHA256, 32);
    lock (gate)
    {
        if (users.ContainsKey(c.Username))
            return Results.Conflict("username is taken");
        var user = new User(users.Count + 1, c.Username, salt, hash);
        users[c.Username] = user;
        return Results.Created($"/users/{user.Id}", new { user.Id, user.Username });
    }
});

app.MapPost("/login", (Credentials c) =>
{
    User? user;
    lock (gate)
        user = c.Username is null ? null : users.GetValueOrDefault(c.Username);
    if (user is null || c.Password is null ||
        !CryptographicOperations.FixedTimeEquals(Rfc2898DeriveBytes.Pbkdf2(c.Password, user.Salt, 100_000, HashAlgorithmName.SHA256, 32), user.Hash))
        return Results.Unauthorized();
    var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
    lock (gate)
        sessions[token] = user.Username;
    return Results.Ok(new { token });
});

app.MapPost("/notes", (NewNote n, HttpRequest req) =>
{
    var user = CurrentUser(req);
    if (user is null)
        return Results.Unauthorized();
    if (string.IsNullOrWhiteSpace(n.Title))
        return Results.BadRequest("title is required");
    lock (gate)
    {
        var note = new Note(++lastNote, n.Title, n.Text ?? "", DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"), user);
        notes[note.Id] = note;
        return Results.Created($"/notes/{note.Id}", note);
    }
});

app.MapGet("/notes", (HttpRequest req) =>
{
    var user = CurrentUser(req);
    if (user is null)
        return Results.Unauthorized();
    lock (gate)
        return Results.Ok(notes.Values.Where(n => n.Owner == user).OrderBy(n => n.Id).ToList());
});

app.MapGet("/notes/{id:int}", (int id, HttpRequest req) =>
{
    var user = CurrentUser(req);
    if (user is null)
        return Results.Unauthorized();
    lock (gate)
        return notes.TryGetValue(id, out var n) && n.Owner == user ? Results.Ok(n) : Results.NotFound();
});

app.MapDelete("/notes/{id:int}", (int id, HttpRequest req) =>
{
    var user = CurrentUser(req);
    if (user is null)
        return Results.Unauthorized();
    lock (gate)
    {
        if (!notes.TryGetValue(id, out var n) || n.Owner != user)
            return Results.NotFound();
        notes.Remove(id);
        return Results.NoContent();
    }
});

app.Run();

record Credentials(string? Username, string? Password);
record User(int Id, string Username, byte[] Salt, byte[] Hash);
record NewNote(string? Title, string? Text);
record Note(int Id, string Title, string Text, string CreatedAt, [property: System.Text.Json.Serialization.JsonIgnore] string Owner);
