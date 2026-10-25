static class Checkout
{
    public static decimal Run(int count)
    {
        var total = Pricing.Total(count);
        return total;
    }
}
