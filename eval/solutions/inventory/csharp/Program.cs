using System.Text.Json;
using System.Text.RegularExpressions;

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();
var items = new Dictionary<string, Item>();
var orders = new List<Order>();
var gate = new object();

app.MapPost("/items", (Item item) =>
{
    if (item.Sku is null || !Regex.IsMatch(item.Sku, "^[A-Z0-9-]{3,20}$") || string.IsNullOrWhiteSpace(item.Name) || item.Stock < 0)
        return Results.BadRequest("sku must be 3-20 of A-Z, 0-9, -; name required; stock >= 0");
    lock (gate)
    {
        if (!items.TryAdd(item.Sku, item))
            return Results.Conflict("sku exists");
        return Results.Created($"/items/{item.Sku}", item);
    }
});

app.MapGet("/items", () =>
{
    lock (gate)
        return items.Values.OrderBy(i => i.Sku, StringComparer.Ordinal).ToList();
});

app.MapPost("/items/{sku}/restock", (string sku, Restock req) =>
{
    lock (gate)
    {
        if (!items.TryGetValue(sku, out var item))
            return Results.NotFound();
        if (req.Amount <= 0)
            return Results.BadRequest("amount must be positive");
        item.Stock += req.Amount;
        return Results.Ok(item);
    }
});

app.MapPost("/orders", (NewOrder req) =>
{
    if (req.Lines is null || req.Lines.Count == 0 || req.Lines.Any(l => l.Qty <= 0))
        return Results.BadRequest("lines must not be empty and qty must be positive");
    var need = req.Lines.GroupBy(l => l.Sku).ToDictionary(g => g.Key, g => g.Sum(l => l.Qty));
    lock (gate)
    {
        foreach (var (sku, qty) in need)
        {
            if (!items.TryGetValue(sku, out var item))
                return Results.NotFound($"unknown sku {sku}");
            if (item.Stock < qty)
                return Results.Conflict($"not enough {sku}");
        }
        foreach (var (sku, qty) in need)
            items[sku].Stock -= qty;
        var order = new Order { Id = orders.Count + 1, Lines = req.Lines, TotalQty = req.Lines.Sum(l => l.Qty) };
        orders.Add(order);
        return Results.Created($"/orders/{order.Id}", order);
    }
});

app.MapPost("/orders/{id:int}/cancel", (int id) =>
{
    lock (gate)
    {
        if (id < 1 || id > orders.Count)
            return Results.NotFound();
        var order = orders[id - 1];
        if (order.Status == "cancelled")
            return Results.Conflict("already cancelled");
        order.Status = "cancelled";
        foreach (var l in order.Lines)
            items[l.Sku].Stock += l.Qty;
        return Results.Ok(order);
    }
});

app.MapGet("/orders", (string? status) =>
{
    if (status is not null && status != "placed" && status != "cancelled")
        return Results.BadRequest("status must be placed or cancelled");
    lock (gate)
        return Results.Ok(orders.Where(o => status is null || o.Status == status).ToList());
});

app.Run();

record Restock(int Amount);
record Line(string Sku, int Qty);
record NewOrder(List<Line>? Lines);

class Item
{
    public string? Sku { get; set; }
    public string? Name { get; set; }
    public int Stock { get; set; }
}

class Order
{
    public int Id { get; set; }
    public List<Line> Lines { get; set; } = [];
    public string Status { get; set; } = "placed";
    public int TotalQty { get; set; }
}
