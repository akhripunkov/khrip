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

await using (var conn = await db.OpenConnectionAsync())
await using (var tx = await conn.BeginTransactionAsync())
{
    await conn.ExecuteAsync("""
        SELECT pg_advisory_xact_lock(hashtext('ledger schema'));
        CREATE TABLE IF NOT EXISTS accounts (
            id bigserial PRIMARY KEY,
            owner text NOT NULL,
            currency text NOT NULL,
            balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0)
        );
        CREATE TABLE IF NOT EXISTS transfers (
            id bigserial PRIMARY KEY,
            from_id bigint NOT NULL REFERENCES accounts,
            to_id bigint NOT NULL REFERENCES accounts,
            amount bigint NOT NULL CHECK (amount > 0),
            created_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
            idempotency_key text UNIQUE
        );
        CREATE INDEX IF NOT EXISTS transfers_from_id ON transfers (from_id, id);
        CREATE INDEX IF NOT EXISTS transfers_to_id ON transfers (to_id, id);
        """, transaction: tx);
    await tx.CommitAsync();
}

const string TransferColumns = """id, from_id AS "from", to_id AS "to", amount, created_at AS createdat""";
string[] currencies = ["USD", "EUR", "GBP"];

app.MapPost("/accounts", async (NewAccount req) =>
{
    if (string.IsNullOrWhiteSpace(req.Owner) || !currencies.Contains(req.Currency))
        return Results.BadRequest("owner is required and currency must be USD, EUR or GBP");
    await using var conn = await db.OpenConnectionAsync();
    var acc = await conn.QuerySingleAsync<Account>("INSERT INTO accounts (owner, currency) VALUES (@Owner, @Currency) RETURNING *", req);
    return Results.Created($"/accounts/{acc.Id}", acc);
});

app.MapGet("/accounts/{id:long}", async (long id) =>
{
    await using var conn = await db.OpenConnectionAsync();
    var acc = await conn.QuerySingleOrDefaultAsync<Account>("SELECT * FROM accounts WHERE id = @id", new { id });
    return acc is null ? Results.NotFound() : Results.Ok(acc);
});

app.MapPost("/accounts/{id:long}/deposit", async (long id, Deposit req) =>
{
    if (req.Amount <= 0)
        return Results.BadRequest("amount must be positive");
    await using var conn = await db.OpenConnectionAsync();
    var acc = await conn.QuerySingleOrDefaultAsync<Account>(
        "UPDATE accounts SET balance = balance + @Amount WHERE id = @id RETURNING *", new { id, req.Amount });
    return acc is null ? Results.NotFound() : Results.Ok(acc);
});

app.MapPost("/transfers", async (NewTransfer req, [FromHeader(Name = "Idempotency-Key")] string? key) =>
{
    if (req.Amount <= 0 || req.From == req.To)
        return Results.BadRequest("amount must be positive and accounts different");
    if (key is { Length: 0 or > 64 })
        return Results.BadRequest("Idempotency-Key must be 1-64 characters");
    await using var conn = await db.OpenConnectionAsync();
    await using var tx = await conn.BeginTransactionAsync();
    if (key is not null)
    {
        await conn.ExecuteAsync("SELECT pg_advisory_xact_lock(hashtextextended(@key, 0))", new { key }, tx);
        var done = await conn.QuerySingleOrDefaultAsync<Transfer>(
            $"SELECT {TransferColumns} FROM transfers WHERE idempotency_key = @key", new { key }, tx);
        if (done is not null)
            return done.From == req.From && done.To == req.To && done.Amount == req.Amount
                ? Results.Created($"/transfers/{done.Id}", done)
                : Results.UnprocessableEntity("Idempotency-Key was used with a different request");
    }
    var locked = (await conn.QueryAsync<Account>(
        "SELECT * FROM accounts WHERE id IN (@From, @To) ORDER BY id FOR UPDATE", req, tx)).ToDictionary(a => a.Id);
    if (!locked.TryGetValue(req.From, out var from) || !locked.TryGetValue(req.To, out var to))
        return Results.NotFound("account not found");
    if (from.Currency != to.Currency)
        return Results.UnprocessableEntity("accounts have different currencies");
    if (from.Balance < req.Amount)
        return Results.Conflict("insufficient funds");
    await conn.ExecuteAsync(
        "UPDATE accounts SET balance = balance + CASE WHEN id = @From THEN -@Amount ELSE @Amount END WHERE id IN (@From, @To)", req, tx);
    var transfer = await conn.QuerySingleAsync<Transfer>(
        $"INSERT INTO transfers (from_id, to_id, amount, idempotency_key) VALUES (@From, @To, @Amount, @key) RETURNING {TransferColumns}",
        new { req.From, req.To, req.Amount, key }, tx);
    await tx.CommitAsync();
    return Results.Created($"/transfers/{transfer.Id}", transfer);
});

app.MapGet("/accounts/{id:long}/transfers", async (long id, long? before, int limit = 20) =>
{
    if (limit is < 1 or > 100)
        return Results.BadRequest("limit must be 1-100");
    await using var conn = await db.OpenConnectionAsync();
    if (!await conn.ExecuteScalarAsync<bool>("SELECT EXISTS (SELECT 1 FROM accounts WHERE id = @id)", new { id }))
        return Results.NotFound();
    var transfers = await conn.QueryAsync<Transfer>(
        $"SELECT {TransferColumns} FROM transfers WHERE (from_id = @id OR to_id = @id) AND id < @before ORDER BY id DESC LIMIT @limit",
        new { id, before = before ?? long.MaxValue, limit });
    return Results.Ok(transfers);
});

app.MapGet("/stats", async () =>
{
    await using var conn = await db.OpenConnectionAsync();
    var (accounts, transfers, usd, eur, gbp) = await conn.QuerySingleAsync<(long, long, long, long, long)>("""
        SELECT count(*), (SELECT count(*) FROM transfers),
               coalesce(sum(balance) FILTER (WHERE currency = 'USD'), 0)::bigint,
               coalesce(sum(balance) FILTER (WHERE currency = 'EUR'), 0)::bigint,
               coalesce(sum(balance) FILTER (WHERE currency = 'GBP'), 0)::bigint
        FROM accounts
        """);
    return new { accounts, transfers, balances = new Dictionary<string, long> { ["USD"] = usd, ["EUR"] = eur, ["GBP"] = gbp } };
});

app.Run();

record NewAccount(string? Owner, string? Currency);
record Deposit(long Amount);
record NewTransfer(long From, long To, long Amount);
record Account(long Id, string Owner, string Currency, long Balance);
record Transfer(long Id, long From, long To, long Amount, DateTime CreatedAt);
