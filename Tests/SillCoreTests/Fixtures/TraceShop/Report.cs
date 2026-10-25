public static class Report
{
    public static void Print(int count) => Console.WriteLine($"{count} cost {Pricing.Total(count)}");
}
