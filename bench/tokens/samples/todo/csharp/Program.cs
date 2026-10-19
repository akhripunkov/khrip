using System.Collections.Concurrent;
using System.Text.Json.Serialization;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));
var app = builder.Build();
var tasks = new ConcurrentDictionary<int, TaskItem>();
var lastId = 0;

app.MapPost("/tasks", (NewTask body) =>
{
    if (string.IsNullOrWhiteSpace(body.Title)) return Results.BadRequest("title is required");
    var task = new TaskItem(Interlocked.Increment(ref lastId), body.Title, body.Status, body.Tags ?? []);
    tasks[task.Id] = task;
    return Results.Created($"/tasks/{task.Id}", task);
});

app.MapGet("/tasks", (Status? status, string? tag) =>
    tasks.Values.Where(t => status == null || t.Status == status)
        .Where(t => tag == null || t.Tags.Contains(tag))
        .OrderBy(t => t.Title, StringComparer.Ordinal));

app.MapGet("/tasks/{id:int}", (int id) =>
    tasks.TryGetValue(id, out var task) ? Results.Ok(task) : Results.NotFound());

app.MapPut("/tasks/{id:int}/status", (int id, Status status) =>
{
    if (!tasks.TryGetValue(id, out var task)) return Results.NotFound();
    tasks[id] = task with { Status = status };
    return Results.Ok(tasks[id]);
});

app.MapGet("/stats", () =>
{
    var done = tasks.Values.Count(t => t.Status == Status.Done);
    return new Stats(tasks.Count, done, tasks.Count - done);
});

app.Run("http://0.0.0.0:8080");

enum Status { Todo, Doing, Done }
record NewTask(string Title, Status Status = Status.Todo, string[]? Tags = null);
record TaskItem(int Id, string Title, Status Status, string[] Tags);
record Stats(int Total, int Done, int Open);
