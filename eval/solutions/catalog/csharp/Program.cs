using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower);
var app = builder.Build();
var products = new List<Product>();
var gate = new object();

bool Valid(Product p) => !string.IsNullOrWhiteSpace(p.Name) && !string.IsNullOrWhiteSpace(p.Category) && p.Price >= 0;

app.MapPost("/products", (ProductInput input) =>
{
    var p = new Product(0, input.Name ?? "", input.Category ?? "", input.Price ?? -1, input.Tags ?? []);
    if (!Valid(p))
        return Results.BadRequest("name and category are required, price must not be negative");
    lock (gate)
    {
        p = p with { Id = products.Count + 1 };
        products.Add(p);
    }
    return Results.Created($"/products/{p.Id}", p);
});

app.MapGet("/products/{id:int}", (int id) =>
{
    lock (gate)
        return id >= 1 && id <= products.Count ? Results.Ok(products[id - 1]) : Results.NotFound();
});

app.MapPatch("/products/{id:int}", (int id, ProductInput input) =>
{
    lock (gate)
    {
        if (id < 1 || id > products.Count)
            return Results.NotFound();
        var old = products[id - 1];
        var p = new Product(id, input.Name ?? old.Name, input.Category ?? old.Category, input.Price ?? old.Price, input.Tags ?? old.Tags);
        if (!Valid(p))
            return Results.BadRequest("name and category are required, price must not be negative");
        products[id - 1] = p;
        return Results.Ok(p);
    }
});

app.MapGet("/products", (string? q, string? category, string? tag, double? min_price, double? max_price, string? sort, int? page, int? per_page) =>
{
    int pg = page ?? 1, size = per_page ?? 10;
    if (pg < 1 || size < 1 || size > 100)
        return Results.BadRequest("page must be at least 1, per_page from 1 to 100");
    List<Product> all;
    lock (gate)
        all = products.ToList();
    var items = all.Where(p =>
        (q is null || p.Name.Contains(q, StringComparison.OrdinalIgnoreCase)) &&
        (category is null || p.Category == category) &&
        (tag is null || p.Tags.Contains(tag)) &&
        (min_price is null || p.Price >= min_price) &&
        (max_price is null || p.Price <= max_price));
    items = sort switch
    {
        null => items,
        "price" => items.OrderBy(p => p.Price),
        "-price" => items.OrderByDescending(p => p.Price),
        "name" => items.OrderBy(p => p.Name, StringComparer.Ordinal),
        _ => null!,
    };
    if (items is null)
        return Results.BadRequest("sort must be price, -price or name");
    var list = items.ToList();
    return Results.Ok(new { items = list.Skip((pg - 1) * size).Take(size), total = list.Count, page = pg, per_page = size });
});

app.MapGet("/categories", () =>
{
    lock (gate)
        return products.GroupBy(p => p.Category)
            .OrderBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => new { name = g.Key, count = g.Count(), avg_price = Math.Round(g.Average(p => p.Price), 2, MidpointRounding.AwayFromZero) })
            .ToList();
});

app.Run();

record ProductInput(string? Name, string? Category, double? Price, List<string>? Tags);
record Product(int Id, string Name, string Category, double Price, List<string> Tags);
