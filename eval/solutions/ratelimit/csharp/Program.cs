var app = WebApplication.CreateBuilder(args).Build();
const int Limit = 5;
var length = TimeSpan.FromSeconds(int.TryParse(Environment.GetEnvironmentVariable("WINDOW_SECONDS"), out var s) ? s : 60);
var windows = new Dictionary<string, Window>();
var gate = new object();

Window? Active(string key) =>
    windows.TryGetValue(key, out var w) && DateTime.UtcNow - w.Start < length ? w : null;

int SecondsLeft(Window w) => (int)Math.Ceiling((w.Start + length - DateTime.UtcNow).TotalSeconds);

// Counts the request of the X-API-Key client: remaining requests, or an error result.
(int Remaining, IResult? Error) Take(HttpContext ctx)
{
    var key = ctx.Request.Headers["X-API-Key"].ToString();
    if (key == "")
        return (0, Results.Text("missing X-API-Key", statusCode: 401));
    lock (gate)
    {
        var w = Active(key);
        if (w is null)
            windows[key] = w = new Window { Start = DateTime.UtcNow };
        if (w.Used >= Limit)
        {
            ctx.Response.Headers.RetryAfter = SecondsLeft(w).ToString();
            return (0, Results.Text("too many requests", statusCode: 429));
        }
        w.Used++;
        return (Limit - w.Used, null);
    }
}

app.MapGet("/api/ping", (HttpContext ctx) =>
{
    var (remaining, error) = Take(ctx);
    return error ?? Results.Ok(new { pong = true, remaining });
});

app.MapGet("/api/time", (HttpContext ctx) =>
{
    var (_, error) = Take(ctx);
    return error ?? Results.Ok(new { time = DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ") });
});

app.MapGet("/limits/{key}", (string key) =>
{
    lock (gate)
    {
        var w = Active(key);
        var used = w?.Used ?? 0;
        return new { key, used, remaining = Limit - used, reset_in = w is null ? 0 : SecondsLeft(w) };
    }
});

app.Run();

class Window
{
    public DateTime Start;
    public int Used;
}
