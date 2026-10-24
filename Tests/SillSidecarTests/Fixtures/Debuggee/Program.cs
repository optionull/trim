// A program to debug: a loop calling a method, an exception it handles and then one it does not. With --wait it ticks
// until it is stopped instead, for a debugger to attach to.
if (args.Contains("--wait"))
{
    for (int tick = 0; ; tick++) Clock.Tick(tick);
}
var orders = new List<Order>();
for (int i = 0; i < 10; i++)
{
    orders.Add(new Order(i, $"customer-{i}", Pricing.Total(i)));
}
try { throw new InvalidOperationException("handled on purpose"); } catch (InvalidOperationException) { }
Console.WriteLine($"{orders.Count} orders, the first for {orders[0].Customer}");
throw new ArgumentException($"not handled: {orders.Count} orders");

record Order(int Id, string Customer, double Total);

static class Pricing
{
    public static double Total(int seed)
    {
        double total = 0;
        for (int i = 0; i < 100; i++) total += seed * i;
        return total;
    }
}

static class Clock
{
    public static void Tick(int tick)
    {
        var now = DateTime.UtcNow;
        Thread.Sleep(100);
    }
}
