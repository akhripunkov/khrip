var app = WebApplication.CreateBuilder(args).Build();
var polls = new List<Poll>();
var gate = new object();

app.MapPost("/polls", (NewPoll req) =>
{
    var options = req.Options ?? [];
    if (string.IsNullOrWhiteSpace(req.Question) || options.Count is < 2 or > 10 ||
        options.Any(string.IsNullOrWhiteSpace) || options.Distinct().Count() != options.Count)
        return Results.BadRequest("question and 2-10 different options are required");
    lock (gate)
    {
        var poll = new Poll { Id = polls.Count + 1, Question = req.Question, Options = options.Select(o => new Option { Text = o }).ToList() };
        polls.Add(poll);
        return Results.Created($"/polls/{poll.Id}", poll);
    }
});

app.MapGet("/polls/{id:int}", (int id) =>
{
    lock (gate)
        return id >= 1 && id <= polls.Count ? Results.Ok(polls[id - 1]) : Results.NotFound();
});

app.MapGet("/polls", (bool? open) =>
{
    lock (gate)
        return polls.Where(p => open is null || p.Closed != open).ToList();
});

app.MapPost("/polls/{id:int}/votes", (int id, VoteRequest req, HttpRequest http) =>
{
    var voter = http.Headers["X-Voter-Id"].ToString();
    if (voter == "")
        return Results.Unauthorized();
    lock (gate)
    {
        if (id < 1 || id > polls.Count)
            return Results.NotFound();
        var poll = polls[id - 1];
        if (poll.Closed)
            return Results.StatusCode(403);
        if (req.Option < 0 || req.Option >= poll.Options.Count)
            return Results.BadRequest("no such option");
        if (!poll.Voters.Add(voter))
            return Results.Conflict("already voted");
        poll.Options[req.Option].Votes++;
        return Results.Ok(poll);
    }
});

app.MapPost("/polls/{id:int}/close", (int id) =>
{
    lock (gate)
    {
        if (id < 1 || id > polls.Count)
            return Results.NotFound();
        polls[id - 1].Closed = true;
        return Results.Ok(polls[id - 1]);
    }
});

app.MapGet("/polls/{id:int}/results", (int id) =>
{
    lock (gate)
    {
        if (id < 1 || id > polls.Count)
            return Results.NotFound();
        var options = polls[id - 1].Options;
        var total = options.Sum(o => o.Votes);
        var results = options
            .Select(o => new { text = o.Text, votes = o.Votes, percent = total == 0 ? 0 : Math.Round(o.Votes * 100.0 / total, 1, MidpointRounding.AwayFromZero) })
            .OrderByDescending(r => r.votes)
            .ToList();
        return Results.Ok(new { total, results });
    }
});

app.Run();

record NewPoll(string? Question, List<string>? Options);
record VoteRequest(int Option);

class Option
{
    public string Text { get; set; } = "";
    public int Votes { get; set; }
}

class Poll
{
    public int Id { get; set; }
    public string Question { get; set; } = "";
    public List<Option> Options { get; set; } = [];
    public bool Closed { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public HashSet<string> Voters { get; } = [];
}
