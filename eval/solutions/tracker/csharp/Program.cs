using System.Data;
using System.Text.Json;
using System.Web;
using Dapper;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();

var url = new Uri(app.Configuration["DATABASE_URL"] ?? throw new InvalidOperationException("DATABASE_URL is not set"));
var userInfo = url.UserInfo.Split(':', 2);
var sslMode = HttpUtility.ParseQueryString(url.Query)["sslmode"];
await using var db = NpgsqlDataSource.Create(new NpgsqlConnectionStringBuilder
{
    Host = url.Host,
    Port = url.Port,
    Database = url.AbsolutePath.TrimStart('/'),
    Username = Uri.UnescapeDataString(userInfo[0]),
    Password = Uri.UnescapeDataString(userInfo[1]),
    SslMode = sslMode is null ? SslMode.Prefer : Enum.Parse<SslMode>(sslMode.Replace("-", ""), ignoreCase: true),
}.ConnectionString);
DefaultTypeMap.MatchNamesWithUnderscores = true;

await using (var conn = await db.OpenConnectionAsync())
await using (var tx = await conn.BeginTransactionAsync())
{
    await conn.ExecuteAsync("""
        SELECT pg_advisory_xact_lock(hashtext('tracker schema'));
        CREATE TABLE IF NOT EXISTS users (
            id bigserial PRIMARY KEY,
            email text NOT NULL UNIQUE,
            name text NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
            key text PRIMARY KEY,
            name text NOT NULL,
            owner_id bigint NOT NULL REFERENCES users,
            last_number int NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS issues (
            key text GENERATED ALWAYS AS (project || '-' || number) STORED UNIQUE,
            project text NOT NULL REFERENCES projects,
            number int NOT NULL,
            title text NOT NULL,
            status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'done')),
            priority text NOT NULL CHECK (priority IN ('low', 'medium', 'high')),
            assignee_id bigint REFERENCES users,
            created_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
            updated_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
            PRIMARY KEY (project, number)
        );
        """, transaction: tx);
    await tx.CommitAsync();
}

string[] statuses = ["open", "in_progress", "done"];
string[] priorities = ["low", "medium", "high"];

app.MapPost("/users", async (NewUser req) =>
{
    var email = req.Email?.ToLowerInvariant();
    if (email?.Split('@') is not [{ Length: > 0 }, { Length: > 0 }] || email.Any(char.IsWhiteSpace) || string.IsNullOrWhiteSpace(req.Name))
        return Results.BadRequest("email must be an address and name must not be blank");
    await using var conn = await db.OpenConnectionAsync();
    var user = await conn.QuerySingleOrDefaultAsync<User>(
        "INSERT INTO users (email, name) VALUES (@email, @Name) ON CONFLICT (email) DO NOTHING RETURNING *", new { email, req.Name });
    return user is null ? Results.Conflict("email exists") : Results.Created($"/users/{user.Id}", user);
});

app.MapPost("/projects", async (NewProject req) =>
{
    if (req.Key is not { Length: >= 2 and <= 5 } || !req.Key.All(char.IsAsciiLetterUpper) || string.IsNullOrWhiteSpace(req.Name) || req.OwnerId is null)
        return Results.BadRequest("key must be 2-5 letters A-Z, name must not be blank, owner_id is required");
    await using var conn = await db.OpenConnectionAsync();
    try
    {
        var project = await conn.QuerySingleAsync<Project>(
            "INSERT INTO projects (key, name, owner_id) VALUES (@Key, @Name, @OwnerId) RETURNING key, name, owner_id", req);
        return Results.Created($"/projects/{project.Key}", project);
    }
    catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
    {
        return Results.Conflict("project exists");
    }
    catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.ForeignKeyViolation)
    {
        return Results.NotFound("owner not found");
    }
});

// The project row lock taken by the counter update orders concurrent inserts, and a failed insert
// rolls the counter back, so numbers are neither repeated nor skipped.
app.MapPost("/projects/{key}/issues", async (string key, NewIssue req) =>
{
    var priority = req.Priority ?? "medium";
    if (!IsValidTitle(req.Title) || !priorities.Contains(priority))
        return Results.BadRequest("title must be 1-200 characters and not blank; priority low, medium or high");
    await using var conn = await db.OpenConnectionAsync();
    await using var tx = await conn.BeginTransactionAsync();
    var number = await conn.QuerySingleOrDefaultAsync<int?>(
        "UPDATE projects SET last_number = last_number + 1 WHERE key = @key RETURNING last_number", new { key }, tx);
    if (number is null)
        return Results.NotFound("project not found");
    try
    {
        var issue = await conn.QuerySingleAsync<Issue>("""
            INSERT INTO issues (project, number, title, priority, assignee_id)
            VALUES (@key, @number, @Title, @priority, @AssigneeId)
            RETURNING *
            """, new { key, number, req.Title, priority, req.AssigneeId }, tx);
        await tx.CommitAsync();
        return Results.Created($"/issues/{issue.Key}", issue);
    }
    catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.ForeignKeyViolation)
    {
        return Results.NotFound("assignee not found");
    }
});

app.MapGet("/issues/{key}", async (string key) =>
{
    await using var conn = await db.OpenConnectionAsync();
    var issue = await conn.QuerySingleOrDefaultAsync<Issue>("SELECT * FROM issues WHERE key = @key", new { key });
    return issue is null ? Results.NotFound() : Results.Ok(issue);
});

app.MapPatch("/issues/{key}", async (string key, IssuePatch req) =>
{
    if (!TryGetText(req.Title, IsValidTitle, out var title) || !TryGetText(req.Status, statuses.Contains, out var status)
        || !TryGetText(req.Priority, priorities.Contains, out var priority))
        return Results.BadRequest("title must be 1-200 characters and not blank; status open, in_progress or done; priority low, medium or high");
    long? assigneeId = null;
    if (req.AssigneeId.ValueKind == JsonValueKind.Number && req.AssigneeId.TryGetInt64(out var id))
        assigneeId = id;
    else if (req.AssigneeId.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null))
        return Results.BadRequest("assignee_id must be a user id or null");
    await using var conn = await db.OpenConnectionAsync();
    try
    {
        var issue = await conn.QuerySingleOrDefaultAsync<Issue>("""
            UPDATE issues SET title = coalesce(@title, title), status = coalesce(@status, status),
                priority = coalesce(@priority, priority),
                assignee_id = CASE WHEN @setAssignee THEN @assigneeId ELSE assignee_id END,
                updated_at = date_trunc('second', now())
            WHERE key = @key
            RETURNING *
            """, new { key, title, status, priority, setAssignee = req.AssigneeId.ValueKind != JsonValueKind.Undefined, assigneeId });
        return issue is null ? Results.NotFound() : Results.Ok(issue);
    }
    catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.ForeignKeyViolation)
    {
        return Results.NotFound("assignee not found");
    }
});

app.MapDelete("/issues/{key}", async (string key) =>
{
    await using var conn = await db.OpenConnectionAsync();
    var deleted = await conn.ExecuteAsync("DELETE FROM issues WHERE key = @key", new { key });
    return deleted == 0 ? Results.NotFound() : Results.NoContent();
});

app.MapGet("/projects/{key}/issues", async (string key, string? status, [FromQuery(Name = "assignee_id")] string? assigneeId, string? q) =>
{
    long assignee = 0;
    if (status is not null && !statuses.Contains(status) || assigneeId is not (null or "none") && !long.TryParse(assigneeId, out assignee))
        return Results.BadRequest("status must be open, in_progress or done; assignee_id a user id or none");
    List<string> filters = ["project = @key"];
    if (status is not null)
        filters.Add("status = @status");
    if (assigneeId == "none")
        filters.Add("assignee_id IS NULL");
    else if (assigneeId is not null)
        filters.Add("assignee_id = @assignee");
    if (q is not null)
        filters.Add("strpos(lower(title), lower(@q)) > 0");
    await using var conn = await db.OpenConnectionAsync();
    if (!await conn.ExecuteScalarAsync<bool>("SELECT EXISTS (SELECT 1 FROM projects WHERE key = @key)", new { key }))
        return Results.NotFound();
    var issues = await conn.QueryAsync<Issue>(
        $"SELECT * FROM issues WHERE {string.Join(" AND ", filters)} ORDER BY number", new { key, status, assignee, q });
    return Results.Ok(issues);
});

app.MapGet("/projects/{key}/summary", async (string key) =>
{
    await using var conn = await db.OpenConnectionAsync();
    await using var tx = await conn.BeginTransactionAsync(IsolationLevel.RepeatableRead);
    await using var results = await conn.QueryMultipleAsync("""
        SELECT count(i.number) AS total,
               count(*) FILTER (WHERE i.status = 'open') AS open,
               count(*) FILTER (WHERE i.status = 'in_progress') AS in_progress,
               count(*) FILTER (WHERE i.status = 'done') AS done
        FROM projects p LEFT JOIN issues i ON i.project = p.key
        WHERE p.key = @key
        GROUP BY p.key;
        SELECT u.id, u.name, count(*) AS active
        FROM issues i JOIN users u ON u.id = i.assignee_id
        WHERE i.project = @key AND i.status <> 'done'
        GROUP BY u.id
        ORDER BY active DESC, u.id;
        """, new { key }, tx);
    var counts = await results.ReadSingleOrDefaultAsync<Counts>();
    if (counts is null)
        return Results.NotFound();
    var assignees = await results.ReadAsync<Assignee>();
    return Results.Ok(new { counts.Total, counts.Open, counts.InProgress, counts.Done, assignees });
});

app.Run();

static bool IsValidTitle(string? title) => !string.IsNullOrWhiteSpace(title) && title.EnumerateRunes().Count() <= 200;

// An absent field gives null; a given one, null included, must be a valid string.
static bool TryGetText(JsonElement field, Func<string, bool> isValid, out string? text)
{
    text = field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    return field.ValueKind == JsonValueKind.Undefined || text is not null && isValid(text);
}

record NewUser(string? Email, string? Name);
record User(long Id, string Email, string Name);
record NewProject(string? Key, string? Name, long? OwnerId);
record Project(string Key, string Name, long OwnerId);
record NewIssue(string? Title, string? Priority, long? AssigneeId);
record IssuePatch(JsonElement Title, JsonElement Status, JsonElement Priority, JsonElement AssigneeId);
record Counts(long Total, long Open, long InProgress, long Done);
record Assignee(long Id, string Name, long Active);
record Issue(string Key, string Project, int Number, string Title, string Status, string Priority, long? AssigneeId, DateTime CreatedAt, DateTime UpdatedAt);
