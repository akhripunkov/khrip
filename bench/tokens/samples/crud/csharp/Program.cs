using System.Collections.Concurrent;

var app = WebApplication.CreateSlimBuilder(args).Build();
var users = new ConcurrentDictionary<int, User>();
var nextId = 0;

app.MapPost("/users", (NewUser input) =>
{
    if (string.IsNullOrEmpty(input.Name)) return Results.BadRequest("name is required");
    if (!input.Email.Contains('@')) return Results.BadRequest("email is invalid");
    if (input.Age is < 0 or > 150) return Results.BadRequest("age is out of range");
    var user = new User(Interlocked.Increment(ref nextId), input.Name, input.Email, input.Age);
    users[user.Id] = user;
    return Results.Created($"/users/{user.Id}", user);
});

app.MapGet("/users/{id:int}", (int id) =>
    users.TryGetValue(id, out var user) ? Results.Ok(user) : Results.NotFound());

app.MapGet("/users", () => users.Values.OrderBy(u => u.Id));

app.MapDelete("/users/{id:int}", (int id) =>
    users.TryRemove(id, out _) ? Results.NoContent() : Results.NotFound());

app.Run("http://0.0.0.0:8080");

record User(int Id, string Name, string Email, int Age);
record NewUser(string Name, string Email, int Age);
