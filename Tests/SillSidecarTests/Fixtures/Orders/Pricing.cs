namespace Orders;

/// <summary>An order's price.</summary>
public static class Pricing
{
    public static double Total(int seed) => seed * 2.0;
}
