using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

var app = WebApplication.CreateBuilder(args).Build();
var links = new ConcurrentDictionary<string, Link>();
const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

app.MapPost("/links", (NewLink req) =>
{
    if (req.Url is null || !(req.Url.StartsWith("http://") || req.Url.StartsWith("https://")))
        return Results.BadRequest("url must start with http:// or https://");
    if (req.Code is not null && !Regex.IsMatch(req.Code, "^[A-Za-z0-9_-]{3,32}$"))
        return Results.BadRequest("code must be 3-32 letters, digits, - or _");
    if (req.Code is not null)
    {
        var custom = new Link(req.Code, req.Url);
        return links.TryAdd(req.Code, custom) ? Results.Created($"/links/{req.Code}", custom) : Results.Conflict("code is taken");
    }
    while (true)
    {
        var link = new Link(RandomNumberGenerator.GetString(Alphabet, 7), req.Url);
        if (links.TryAdd(link.Code, link))
            return Results.Created($"/links/{link.Code}", link);
    }
});

app.MapGet("/{code}", (string code) =>
{
    if (!links.TryGetValue(code, out var link))
        return Results.NotFound();
    lock (link) link.Clicks++;
    return Results.Redirect(link.Url);
});

app.MapGet("/links", () => links.Values.OrderByDescending(l => l.Clicks).ThenBy(l => l.Code, StringComparer.Ordinal));

app.MapGet("/links/{code}", (string code) =>
    links.TryGetValue(code, out var link) ? Results.Ok(link) : Results.NotFound());

app.MapDelete("/links/{code}", (string code) =>
    links.TryRemove(code, out _) ? Results.NoContent() : Results.NotFound());

app.Run();

record NewLink(string? Url, string? Code);

class Link(string code, string url)
{
    public string Code { get; } = code;
    public string Url { get; } = url;
    public int Clicks { get; set; }
}
