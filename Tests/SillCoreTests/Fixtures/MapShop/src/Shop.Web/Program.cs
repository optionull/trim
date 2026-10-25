var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
app.MapGet("/total/{count:int}", (int count) => Shop.Pricing.Total(count));
app.Run();
