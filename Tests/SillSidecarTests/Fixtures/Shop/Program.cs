// A small shop that calls itself: requests, logs, a trace per order and a counter, for sill's telemetry.
using System.Diagnostics;
using System.Diagnostics.Metrics;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(args.FirstOrDefault(a => a.StartsWith("http")) ?? "http://127.0.0.1:5199");
var app = builder.Build();
var source = new ActivitySource("Shop");
var meter = new Meter("Shop");
var orders = meter.CreateCounter<int>("shop.orders");
var logger = app.Logger;

app.MapGet("/order/{id:int}", (int id) =>
{
    using var activity = source.StartActivity("price order");
    activity?.SetTag("order.id", id);
    Thread.Sleep(id % 7 == 0 ? 120 : 5);
    orders.Add(1);
    if (id % 5 == 0) logger.LogWarning("Order {Id} is slow to price", id);
    else logger.LogInformation("Priced order {Id}", id);
    return Results.Ok(new { id, total = id * 3.5 });
});

app.Lifetime.ApplicationStarted.Register(() => _ = Task.Run(async () =>
{
    using var http = new HttpClient();
    var url = app.Urls.First();
    for (int i = 1; ; i++)
    {
        try { await http.GetAsync($"{url}/order/{i}"); } catch { }
        await Task.Delay(200);
    }
}));

app.Run();
