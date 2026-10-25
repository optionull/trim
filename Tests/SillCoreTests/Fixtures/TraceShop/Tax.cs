static class Tax
{
    const decimal Rate = 0.21m;

    public static decimal Of(decimal amount) => Math.Round(amount * Rate, 2);
}
