using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();
var accounts = new Dictionary<int, Account>();
var transfers = new List<Transfer>();
var gate = new object();

app.MapPost("/accounts", (NewAccount req) =>
{
    if (string.IsNullOrWhiteSpace(req.Owner))
        return Results.BadRequest("owner is required");
    lock (gate)
    {
        var acc = new Account { Id = accounts.Count + 1, Owner = req.Owner };
        accounts[acc.Id] = acc;
        return Results.Created($"/accounts/{acc.Id}", acc);
    }
});

app.MapGet("/accounts/{id:int}", (int id) =>
{
    lock (gate)
        return accounts.TryGetValue(id, out var acc) ? Results.Ok(acc) : Results.NotFound();
});

app.MapPost("/accounts/{id:int}/deposit", (int id, AmountRequest req) =>
{
    lock (gate)
    {
        if (!accounts.TryGetValue(id, out var acc))
            return Results.NotFound();
        if (req.Amount <= 0)
            return Results.BadRequest("amount must be positive");
        acc.Balance += req.Amount;
        return Results.Ok(acc);
    }
});

app.MapPost("/transfers", (NewTransfer req) =>
{
    if (req.Amount <= 0 || req.FromId == req.ToId)
        return Results.BadRequest("amount must be positive and accounts different");
    lock (gate)
    {
        if (!accounts.TryGetValue(req.FromId, out var from) || !accounts.TryGetValue(req.ToId, out var to))
            return Results.NotFound();
        if (from.Balance < req.Amount)
            return Results.Conflict("insufficient funds");
        from.Balance -= req.Amount;
        to.Balance += req.Amount;
        var t = new Transfer(transfers.Count + 1, req.FromId, req.ToId, req.Amount,
            DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"));
        transfers.Add(t);
        return Results.Created($"/transfers/{t.Id}", t);
    }
});

app.MapGet("/accounts/{id:int}/transfers", (int id) =>
{
    lock (gate)
    {
        if (!accounts.ContainsKey(id))
            return Results.NotFound();
        return Results.Ok(transfers.Where(t => t.FromId == id || t.ToId == id).Reverse().ToList());
    }
});

app.Run();

record NewAccount(string? Owner);
record AmountRequest(int Amount);
record NewTransfer(int FromId, int ToId, int Amount);
record Transfer(int Id, int FromId, int ToId, int Amount, string CreatedAt);

class Account
{
    public int Id { get; set; }
    public string Owner { get; set; } = "";
    public int Balance { get; set; }
}
