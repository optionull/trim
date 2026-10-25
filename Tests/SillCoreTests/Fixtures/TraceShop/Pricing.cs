static class Pricing
{
    public static decimal Total(int count)
    {
        var net = count * 3.5m;
        return net + Tax.Of(net);
    }
}
