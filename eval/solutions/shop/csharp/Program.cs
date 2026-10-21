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
SqlMapper.AddTypeHandler(new StringArrayHandler());

await using (var conn = await db.OpenConnectionAsync())
await using (var tx = await conn.BeginTransactionAsync())
{
    await conn.ExecuteAsync("""
        SELECT pg_advisory_xact_lock(hashtext('shop schema'));
        CREATE TABLE IF NOT EXISTS categories (
            id bigserial PRIMARY KEY,
            name text NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS categories_name_key ON categories (lower(name));
        CREATE TABLE IF NOT EXISTS products (
            id bigserial PRIMARY KEY,
            name text NOT NULL,
            category_id bigint NOT NULL REFERENCES categories,
            price bigint NOT NULL CHECK (price > 0),
            stock bigint NOT NULL CHECK (stock >= 0),
            tags text[] NOT NULL DEFAULT '{}'
        );
        CREATE TABLE IF NOT EXISTS orders (
            id bigserial PRIMARY KEY,
            customer text NOT NULL,
            status text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'cancelled')),
            total bigint NOT NULL,
            created_at timestamptz NOT NULL DEFAULT date_trunc('second', now())
        );
        CREATE INDEX IF NOT EXISTS orders_customer ON orders (customer, created_at);
        CREATE TABLE IF NOT EXISTS order_lines (
            order_id bigint NOT NULL REFERENCES orders,
            position int NOT NULL,
            product_id bigint NOT NULL REFERENCES products,
            qty bigint NOT NULL CHECK (qty > 0),
            price bigint NOT NULL,
            PRIMARY KEY (order_id, position)
        );
        """, transaction: tx);
    await tx.CommitAsync();
}

app.MapPost("/categories", async (NewCategory req) =>
{
    var name = req.Name?.Trim();
    if (name is not { Length: >= 1 and <= 50 })
        return Results.BadRequest("name must be 1-50 characters");
    await using var conn = await db.OpenConnectionAsync();
    var category = await conn.QuerySingleOrDefaultAsync<Category>(
        "INSERT INTO categories (name) VALUES (@name) ON CONFLICT (lower(name)) DO NOTHING RETURNING *", new { name });
    return category is null ? Results.Conflict("category exists") : Results.Created($"/categories/{category.Id}", category);
});

app.MapGet("/categories", async () =>
{
    await using var conn = await db.OpenConnectionAsync();
    return await conn.QueryAsync<Category>("SELECT * FROM categories ORDER BY name, id");
});

app.MapPost("/products", async (ProductInput req) =>
{
    if (req is not { Name: not null, CategoryId: not null, Price: not null, Stock: not null } || !IsValid(req))
        return Results.BadRequest("name, category_id, price > 0 and stock >= 0 are required; up to 5 tags of 1-20 a-z or 0-9");
    await using var conn = await db.OpenConnectionAsync();
    var product = await conn.QuerySingleOrDefaultAsync<Product>("""
        INSERT INTO products (name, category_id, price, stock, tags)
        SELECT @Name, id, @Price, @Stock, @tags FROM categories WHERE id = @CategoryId
        RETURNING *
        """, new { req.Name, req.CategoryId, req.Price, req.Stock, tags = req.Tags?.Distinct().ToArray() ?? [] });
    return product is null ? Results.NotFound("category not found") : Results.Created($"/products/{product.Id}", product);
});

app.MapGet("/products/{id:long}", async (long id) =>
{
    await using var conn = await db.OpenConnectionAsync();
    var product = await conn.QuerySingleOrDefaultAsync<Product>("SELECT * FROM products WHERE id = @id", new { id });
    return product is null ? Results.NotFound() : Results.Ok(product);
});

app.MapPatch("/products/{id:long}", async (long id, ProductInput req) =>
{
    if (!IsValid(req))
        return Results.BadRequest("name must not be blank, price > 0, stock >= 0; up to 5 tags of 1-20 a-z or 0-9");
    await using var conn = await db.OpenConnectionAsync();
    var product = await conn.QuerySingleOrDefaultAsync<Product>("""
        UPDATE products SET name = coalesce(@Name, name), price = coalesce(@Price, price),
            stock = coalesce(@Stock, stock), tags = coalesce(@tags, tags)
        WHERE id = @id
        RETURNING *
        """, new { id, req.Name, req.Price, req.Stock, tags = req.Tags?.Distinct().ToArray() });
    return product is null ? Results.NotFound() : Results.Ok(product);
});

app.MapGet("/products", async (
    [FromQuery(Name = "category_id")] long? categoryId, string? tag, string? q,
    [FromQuery(Name = "min_price")] long? minPrice, [FromQuery(Name = "max_price")] long? maxPrice,
    [FromQuery(Name = "in_stock")] bool? inStock, string? sort, int page = 1,
    [FromQuery(Name = "per_page")] int perPage = 10) =>
{
    var orderBy = sort switch { null => "id", "price" => "price, id", "-price" => "price DESC, id", "name" => "name, id", _ => null };
    if (orderBy is null || page < 1 || perPage is < 1 or > 50)
        return Results.BadRequest("sort must be price, -price or name; page >= 1; per_page 1-50");
    List<string> filters = ["true"];
    if (categoryId is not null)
        filters.Add("category_id = @categoryId");
    if (tag is not null)
        filters.Add("@tag = ANY(tags)");
    if (q is not null)
        filters.Add("strpos(lower(name), lower(@q)) > 0");
    if (minPrice is not null)
        filters.Add("price >= @minPrice");
    if (maxPrice is not null)
        filters.Add("price <= @maxPrice");
    if (inStock == true)
        filters.Add("stock > 0");
    var where = string.Join(" AND ", filters);
    await using var conn = await db.OpenConnectionAsync();
    await using var results = await conn.QueryMultipleAsync($"""
        SELECT count(*) FROM products WHERE {where};
        SELECT * FROM products WHERE {where} ORDER BY {orderBy} LIMIT @perPage OFFSET @offset;
        """, new { categoryId, tag, q, minPrice, maxPrice, perPage, offset = (page - 1L) * perPage });
    var total = await results.ReadSingleAsync<long>();
    var items = await results.ReadAsync<Product>();
    return Results.Ok(new { items, total });
});

app.MapPost("/orders", async (NewOrder req) =>
{
    var customer = req.Customer?.ToLowerInvariant();
    if (customer?.Split('@') is not [{ Length: > 0 }, { Length: > 0 }] || customer.Any(char.IsWhiteSpace))
        return Results.BadRequest("customer must be an email");
    if (req.Lines is not { Count: > 0 } || req.Lines.Any(l => l is not { Qty: > 0 }))
        return Results.BadRequest("lines must not be empty and qty must be positive");
    var wanted = req.Lines.GroupBy(l => l.ProductId, (id, same) => new NewLine(id, same.Sum(l => l.Qty))).ToList();
    var ids = wanted.Select(l => l.ProductId).ToArray();
    await using var conn = await db.OpenConnectionAsync();
    await using var tx = await conn.BeginTransactionAsync();
    var products = (await conn.QueryAsync<(long Id, long Price, long Stock)>(
        "SELECT id, price, stock FROM products WHERE id = ANY(@ids) ORDER BY id FOR UPDATE", new { ids }, tx)).ToDictionary(p => p.Id);
    if (products.Count < ids.Length)
        return Results.NotFound("unknown product");
    if (wanted.Any(l => products[l.ProductId].Stock < l.Qty))
        return Results.Conflict("not enough stock");
    var lines = wanted.Select(l => new Line(l.ProductId, l.Qty, products[l.ProductId].Price)).ToList();
    var order = await conn.QuerySingleAsync<Order>(
        "INSERT INTO orders (customer, total) VALUES (@customer, @total) RETURNING *",
        new { customer, total = lines.Sum(l => l.Qty * l.Price) }, tx);
    await conn.ExecuteAsync("""
        UPDATE products p SET stock = p.stock - l.qty FROM unnest(@ids, @qtys) AS l(id, qty) WHERE p.id = l.id;
        INSERT INTO order_lines (order_id, position, product_id, qty, price)
        SELECT @orderId, position, id, qty, price FROM unnest(@ids, @qtys, @prices) WITH ORDINALITY AS l(id, qty, price, position);
        """, new { orderId = order.Id, ids, qtys = lines.Select(l => l.Qty).ToArray(), prices = lines.Select(l => l.Price).ToArray() }, tx);
    await tx.CommitAsync();
    return Results.Created($"/orders/{order.Id}", order with { Lines = lines });
});

app.MapPost("/orders/{id:long}/cancel", async (long id) =>
{
    await using var conn = await db.OpenConnectionAsync();
    await using var tx = await conn.BeginTransactionAsync();
    var order = await conn.QuerySingleOrDefaultAsync<Order>("SELECT * FROM orders WHERE id = @id FOR UPDATE", new { id }, tx);
    if (order is null)
        return Results.NotFound();
    if (order.Status == "cancelled")
        return Results.Conflict("order is already cancelled");
    // Products are locked in id order, as in POST /orders, so the two cannot deadlock.
    await conn.ExecuteAsync("""
        SELECT 1 FROM products WHERE id IN (SELECT product_id FROM order_lines WHERE order_id = @id) ORDER BY id FOR UPDATE;
        UPDATE products p SET stock = p.stock + l.qty FROM order_lines l WHERE l.order_id = @id AND p.id = l.product_id;
        UPDATE orders SET status = 'cancelled' WHERE id = @id;
        """, new { id }, tx);
    await tx.CommitAsync();
    return Results.Ok((await WithLines(conn, [order with { Status = "cancelled" }]))[0]);
});

app.MapGet("/customers/{email}/orders", async (string email) =>
{
    await using var conn = await db.OpenConnectionAsync();
    var orders = await conn.QueryAsync<Order>(
        "SELECT * FROM orders WHERE customer = @customer ORDER BY created_at DESC, id DESC", new { customer = email.ToLowerInvariant() });
    return await WithLines(conn, orders);
});

app.MapGet("/stats/categories", async () =>
{
    await using var conn = await db.OpenConnectionAsync();
    return await conn.QueryAsync<CategoryStats>("""
        SELECT c.name AS category, count(p.id) AS products,
               coalesce(sum(s.units), 0)::bigint AS units_sold, coalesce(sum(s.revenue), 0)::bigint AS revenue
        FROM categories c
        LEFT JOIN products p ON p.category_id = c.id
        LEFT JOIN (
            SELECT l.product_id, sum(l.qty) AS units, sum(l.qty * l.price) AS revenue
            FROM order_lines l JOIN orders o ON o.id = l.order_id
            WHERE o.status = 'placed'
            GROUP BY l.product_id
        ) s ON s.product_id = p.id
        GROUP BY c.id
        ORDER BY revenue DESC, c.name
        """);
});

app.Run();

static bool IsValid(ProductInput p) =>
    p is { Price: null or > 0, Stock: null or >= 0 }
    && (p.Name is null || !string.IsNullOrWhiteSpace(p.Name))
    && (p.Tags is null || (p.Tags.Distinct().Count() <= 5
        && p.Tags.All(t => t is { Length: >= 1 and <= 20 } && t.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c)))));

static async Task<List<Order>> WithLines(NpgsqlConnection conn, IEnumerable<Order> orders)
{
    var list = orders.ToList();
    var lines = (await conn.QueryAsync<(long OrderId, long ProductId, long Qty, long Price)>(
        "SELECT order_id, product_id, qty, price FROM order_lines WHERE order_id = ANY(@ids) ORDER BY position",
        new { ids = list.Select(o => o.Id).ToArray() })).ToLookup(l => l.OrderId, l => new Line(l.ProductId, l.Qty, l.Price));
    return list.Select(o => o with { Lines = lines[o.Id].ToList() }).ToList();
}

record NewCategory(string? Name);
record Category(long Id, string Name);
record ProductInput(string? Name, long? CategoryId, long? Price, long? Stock, string[]? Tags);
record Product(long Id, string Name, long CategoryId, long Price, long Stock, string[] Tags);
record NewOrder(string? Customer, List<NewLine>? Lines);
record NewLine(long ProductId, long Qty);
record Line(long ProductId, long Qty, long Price);
record CategoryStats(string Category, long Products, long UnitsSold, long Revenue);

record Order(long Id, string Customer, string Status, long Total, DateTime CreatedAt)
{
    public List<Line> Lines { get; init; } = [];
}

class StringArrayHandler : SqlMapper.TypeHandler<string[]>
{
    public override string[] Parse(object value) => (string[])value;
    public override void SetValue(IDbDataParameter parameter, string[]? value) => parameter.Value = value;
}
