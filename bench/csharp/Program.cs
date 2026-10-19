// Эталонный сервер на C#: ASP.NET Core Minimal API (Kestrel), без логирования,
// JSON через source generator — так, как его настраивают для максимальной скорости.
using System.Text.Json.Serialization;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.Services.ConfigureHttpJsonOptions(options =>
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));

var app = builder.Build();

app.MapGet("/plaintext", () => "Hello, World!");
app.MapGet("/json", () => new Greeting("Hello, World!"));

var port = Environment.GetEnvironmentVariable("PORT") ?? "8080";
app.Run($"http://0.0.0.0:{port}");

record Greeting(string Message);

[JsonSerializable(typeof(Greeting))]
partial class AppJsonContext : JsonSerializerContext;
