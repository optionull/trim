// A sample to profile: a hot loop (Pricing.Total) and a cache that only grows (OrderCache.Remember).
var started = DateTime.UtcNow;
while (DateTime.UtcNow - started < TimeSpan.FromSeconds(double.Parse(args.FirstOrDefault() ?? "30")))
{
    for (int i = 0; i < 2000; i++) OrderCache.Remember(new Order(i, $"customer-{i}", Pricing.Total(i)));
    Thread.Sleep(5);
}
Console.WriteLine($"cached {OrderCache.Count}");

record Order(int Id, string Customer, double Total);

static class Pricing
{
    public static double Total(int seed)
    {
        double total = 0;
        for (int i = 0; i < 20_000; i++) total += Math.Sqrt(seed + i) * Math.Sin(i);
        return total;
    }
}

static class OrderCache
{
    static readonly List<Order> orders = [];
    public static int Count => orders.Count;
    public static void Remember(Order order) => orders.Add(order);
}
