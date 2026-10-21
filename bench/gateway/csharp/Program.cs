// Шлюз: цена товара из сервиса UPSTREAM с налогом 20%.
var app = WebApplication.CreateBuilder(args).Build();
var up = Environment.GetEnvironmentVariable("UPSTREAM") ?? "http://127.0.0.1:9090";
var http = new HttpClient();

app.MapGet("/quote", async (int id) =>
{
    try
    {
        var item = await http.GetFromJsonAsync<Item>($"{up}/item?id={id}");
        if (item is not null)
            return Results.Json(new Quote(item.Id, item.Name, item.Price * 120 / 100));
    }
    catch (HttpRequestException) { }
    return Results.Text("upstream failed", statusCode: 502);
});

app.Run();

record Item(int Id, string Name, int Price);
record Quote(int Id, string Name, int Total);
